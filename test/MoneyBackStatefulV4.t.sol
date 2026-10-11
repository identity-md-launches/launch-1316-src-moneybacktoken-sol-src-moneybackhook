// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackHook} from "src/MoneyBackHook.sol";
import {MoneyBackToken} from "src/MoneyBackToken.sol";
import {MoneyBackRouter} from "src/MoneyBackRouter.sol";
import {RealV4Environment, IntegrationIMD} from "./MoneyBackRealV4.t.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {PoolId} from "./vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "./vendor/v4-core/src/types/Currency.sol";
import {CustomRevert} from "./vendor/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "./vendor/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "./vendor/v4-core/src/libraries/Hooks.sol";
import {Lock} from "./vendor/v4-core/src/libraries/Lock.sol";
import {NonzeroDeltaCount} from "./vendor/v4-core/src/libraries/NonzeroDeltaCount.sol";

interface VmSequence {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function prank(address) external;
    function warp(uint256) external;
}

/// @dev Matches IntegrationIMD's balance mapping at slot zero while allowing a transfer failure
/// at the immutable recipient. Used only by the blocked-sweep scenario, never the random handler.
contract PayoutBlockingIMD {
    mapping(address => uint256) public balanceOf;
    address public blocked;
    error RecipientBlocked(address recipient);

    function blockRecipient(address recipient) external {
        blocked = recipient;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == blocked) revert RecipientBlocked(to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RejectingSeller {
    bool public rejectEth = true;

    function setRejectEth(bool reject) external {
        rejectEth = reject;
    }

    function sell(MoneyBackRouter router, MoneyBackToken token, uint256 amount, uint256 minOut)
        external
        returns (uint256)
    {
        token.approve(address(router), amount);
        return router.sellForEth(amount, minOut, block.timestamp);
    }

    receive() external payable {
        require(!rejectEth, "ETH refused");
    }
}

/// @dev Real swaps with a finite inventory. No minting, deals, storage writes or synthetic swap
/// deltas occur during a sequence. Only the external IMD token is a mock. Handler assertions are
/// enforced with fail-on-revert so a bad oracle or unexpected protocol revert cannot be discarded.
contract MoneyBackV4Handler is IUnlockCallback {
    using StateLibrary for IPoolManager;

    VmSequence private constant vm = VmSequence(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 private constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant ACCRUED = keccak256("FeeAccrued(bool,uint256,uint256,uint256)");

    IPoolManager public immutable manager;
    MoneyBackToken public immutable token;
    MoneyBackHook public immutable hook;
    MoneyBackRouter public immutable router;
    address public immutable treasury;
    address public immutable fixture;
    uint256 public immutable start;
    bool private immutable tokenIs0;
    PoolKey private launchKey;
    PoolKey private publicKey;
    address[3] public actors;

    uint256 public accrued;
    uint256 public gifted;
    uint256 public swept;
    uint256[4] public directCalls;
    uint256 public batches;
    uint256 public buys;
    uint256 public sells;
    uint256 public quotes;
    uint256 public rejections;
    uint256 public partialRejections;

    constructor(
        IPoolManager manager_,
        MoneyBackToken token_,
        MoneyBackHook hook_,
        MoneyBackRouter router_,
        PoolKey memory k
    ) {
        manager = manager_;
        token = token_;
        hook = hook_;
        router = router_;
        fixture = msg.sender;
        treasury = hook_.payout();
        start = hook_.initializedAt();
        launchKey = k;
        tokenIs0 = Currency.unwrap(k.currency0) == address(token_);
        publicKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("sequence trader", i)))));
            vm.prank(actors[i]);
            token_.approve(address(router_), type(uint256).max);
        }
    }

    function _amount(uint96 raw) private pure returns (uint256) {
        // Enough to produce nonzero output, small enough to fill even 64 one-way batches.
        return uint256(raw) % 100e18 + 1e12;
    }

    function _params(uint8 kind, uint256 amount) private view returns (SwapParams memory p) {
        p.zeroForOne = (kind >= 2) == tokenIs0;
        p.amountSpecified = kind % 2 == 0 ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function swap(uint96 raw, uint8 kind) external {
        kind %= 4;
        SwapParams[] memory ps = new SwapParams[](1);
        ps[0] = _params(kind, _amount(raw));
        _swaps(ps);
        directCalls[kind]++;
    }

    function batchSwap(uint96 raw, uint8 first) external {
        SwapParams[] memory ps = new SwapParams[](4);
        for (uint8 i; i < 4; ++i) {
            ps[i] = _params(uint8((uint256(first) + i) % 4), _amount(raw) + i);
        }
        // All four fee paths in one unlock; settle only the net debt at the end.
        _swaps(ps);
        batches++;
        for (uint256 i; i < 4; ++i) {
            directCalls[i]++;
        }
    }

    function _swaps(SwapParams[] memory ps) private {
        uint256 beforePending = hook.pending();
        uint256 beforeImd = IntegrationIMD(IMD).balanceOf(address(this));
        uint256 beforeTokens = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta[] memory ds = abi.decode(manager.unlock(abi.encode(uint8(0), abi.encode(ps))), (BalanceDelta[]));
        int256 netImd;
        int256 netTokens;
        for (uint256 i; i < ds.length; ++i) {
            netImd += tokenIs0 ? ds[i].amount1() : ds[i].amount0();
            netTokens += tokenIs0 ? ds[i].amount0() : ds[i].amount1();
            int256 specifiedDelta =
                (ps[i].amountSpecified < 0) == ps[i].zeroForOne ? int256(ds[i].amount0()) : int256(ds[i].amount1());
            require(specifiedDelta == ps[i].amountSpecified, "exact amount lost in real settlement");
        }
        require(int256(IntegrationIMD(IMD).balanceOf(address(this))) - int256(beforeImd) == netImd, "IMD settlement");
        require(int256(token.balanceOf(address(this))) - int256(beforeTokens) == netTokens, "token settlement");
        _recordFees(beforePending, ps.length, ds);
        assertSettled();
    }

    function route(uint96 raw, uint8 actorSeed, bool sell) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = _amount(raw);
        uint256 quoted = _quote(amount, sell);
        require(quoted > 0, "funded quote produced no output");
        uint256 pendingBefore = hook.pending();
        uint256 tokenBefore = token.balanceOf(actor);
        uint256 ethBefore = actor.balance;
        vm.recordLogs();
        vm.prank(actor);
        uint256 got = sell
            ? router.sellForEth(amount, quoted, block.timestamp)
            : router.buyWithEth{value: amount}(quoted, block.timestamp);
        require(got == quoted, "quote differs from execution at unchanged state");
        if (sell) {
            require(tokenBefore - token.balanceOf(actor) == amount, "seller input");
            require(actor.balance - ethBefore == got, "seller ETH proceeds");
            sells++;
        } else {
            require(token.balanceOf(actor) - tokenBefore == got, "buyer token proceeds");
            require(ethBefore - actor.balance == amount, "buyer ETH input");
            buys++;
        }
        _recordFees(pendingBefore, 1, new BalanceDelta[](0));
        assertSettled();
    }

    function quote(uint96 raw, bool sell) external {
        _quote(_amount(raw), sell);
    }

    function _quote(uint256 amount, bool sell) private returns (uint256 result) {
        bytes32 beforeState = economicState();
        result = sell ? router.quoteSell(amount) : router.quoteBuy(amount);
        require(economicState() == beforeState, "quote changed balances, claims or either pool");
        quotes++;
        assertSettled();
    }

    function rejectSlippage(uint96 raw, uint8 actorSeed, bool sell) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = _amount(raw);
        uint256 quoted = _quote(amount, sell);
        bytes memory data = sell
            ? abi.encodeCall(router.sellForEth, (amount, quoted + 1, block.timestamp))
            : abi.encodeCall(router.buyWithEth, (quoted + 1, block.timestamp));
        bytes32 beforeState = economicState();
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(router).call{value: sell ? 0 : amount}(data);
        require(!ok, "slippage accepted");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, quoted, quoted + 1)),
            "wrong failure reason"
        );
        require(economicState() == beforeState, "failed trade retained economic effects");
        rejections++;
        assertSettled();
    }

    function rejectPartialFill(uint96 raw, bool sell) external {
        SwapParams[] memory ps = new SwapParams[](1);
        // Exact-input buy / exact-output sell: IMD is specified, so underfills must revert.
        ps[0] = _params(sell ? 3 : 0, _amount(raw));
        (uint160 price,,,) = manager.getSlot0(launchKey.toId());
        ps[0].sqrtPriceLimitX96 = ps[0].zeroForOne ? price - 1 : price + 1;
        bytes32 beforeState = economicState();
        (bool ok, bytes memory reason) =
            address(manager).call(abi.encodeCall(manager.unlock, (abi.encode(uint8(0), abi.encode(ps)))));
        require(
            !ok
                && keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(
                            CustomRevert.WrappedError.selector,
                            address(hook),
                            IHooks.afterSwap.selector,
                            abi.encodeWithSelector(MoneyBackHook.PartialFill.selector),
                            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                        )
                    ),
            "specified partial fill was not refused"
        );
        require(economicState() == beforeState, "partial fill retained claims or pool effects");
        partialRejections++;
        assertSettled();
    }

    function giftClaims(uint96 raw) external {
        uint256 amount = uint256(raw) % 10e18 + 1;
        manager.unlock(abi.encode(uint8(1), abi.encode(amount)));
        gifted += amount;
        assertSettled();
    }

    function sweep(uint8 actorSeed) external {
        uint256 pendingBefore = hook.pending();
        uint256 walletBefore = IntegrationIMD(IMD).balanceOf(treasury);
        uint256 managerBefore = IntegrationIMD(IMD).balanceOf(address(manager));
        vm.prank(actors[actorSeed % 3]);
        hook.sweep();
        require(hook.pending() == 0, "sweep left claims");
        require(
            IntegrationIMD(IMD).balanceOf(treasury) - walletBefore == pendingBefore, "wrong sweep recipient or amount"
        );
        require(
            managerBefore - IntegrationIMD(IMD).balanceOf(address(manager)) == pendingBefore,
            "claim backing not redeemed"
        );
        swept += pendingBefore;
        assertSettled();
    }

    function elapse(uint16 secondsSeed) external {
        uint256 beforeRate = hook.currentSurchargeBps();
        vm.warp(block.timestamp + uint256(secondsSeed) % 301);
        require(hook.currentSurchargeBps() <= beforeRate, "surcharge rose with time");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "test manager only");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 1) {
            uint256 amount = abi.decode(payload, (uint256));
            manager.mint(address(hook), uint256(uint160(IMD)), amount);
            _settle(Currency.wrap(IMD), -int256(amount));
            return "";
        }
        SwapParams[] memory ps = abi.decode(payload, (SwapParams[]));
        BalanceDelta[] memory ds = new BalanceDelta[](ps.length);
        int256 d0;
        int256 d1;
        for (uint256 i; i < ps.length; ++i) {
            ds[i] = manager.swap(launchKey, ps[i], "");
            d0 += ds[i].amount0();
            d1 += ds[i].amount1();
        }
        _settle(launchKey.currency0, d0);
        _settle(launchKey.currency1, d1);
        return abi.encode(ds);
    }

    function _settle(Currency currency, int256 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        } else if (delta < 0) {
            manager.sync(currency);
            require(
                MoneyBackToken(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta)), "settle transfer"
            );
            manager.settle();
        }
    }

    /// @dev Independent oracle: v4's Swap event reports actual pool movement before hook fees.
    /// Match it to the hook's event and claim increment, without reproducing the inverse formula.
    function _recordFees(uint256 pendingBefore, uint256 expectedCount, BalanceDelta[] memory userDeltas) private {
        VmSequence.Log[] memory logs = vm.getRecordedLogs();
        int128[] memory poolImd = new int128[](expectedCount);
        int128[] memory poolTokens = new int128[](expectedCount);
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP
                    && logs[i].topics[1] == PoolId.unwrap(launchKey.toId())
            ) {
                (int128 a0, int128 a1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                require(fee == 12_500, "LP fee changed");
                poolImd[swaps] = tokenIs0 ? a1 : a0;
                poolTokens[swaps] = tokenIs0 ? a0 : a1;
                swaps++;
            }
        }
        require(swaps == expectedCount, "missing real pool swap");
        uint256 events;
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != ACCRUED) continue;
            uint256 charged = _checkAccrued(logs[i], poolImd[events]);
            if (userDeltas.length != 0) {
                int256 userToken = tokenIs0 ? userDeltas[events].amount0() : userDeltas[events].amount1();
                int256 userImd = tokenIs0 ? userDeltas[events].amount1() : userDeltas[events].amount0();
                require(userToken == poolTokens[events], "hook charged MONEYBACK");
                require(int256(poolImd[events]) - userImd == int256(charged), "fee missing from user delta");
            }
            fees += charged;
            events++;
        }
        require(events == expectedCount, "fee callback missing or double charged");
        require(hook.pending() == pendingBefore + fees, "claim increment differs from fees");
        accrued += fees;
    }

    function _checkAccrued(VmSequence.Log memory log, int256 actualImd) private view returns (uint256 charged) {
        (uint256 base, uint256 surcharge, uint256 leg) = abi.decode(log.data, (uint256, uint256, uint256));
        bool sell = actualImd > 0;
        require(uint256(log.topics[1]) == (sell ? 1 : 0), "fee event wrong direction");
        require(leg == uint256(sell ? actualImd : -actualImd), "fee not based on actual pool IMD leg");
        charged = base + surcharge;
        uint256 elapsed = block.timestamp - start;
        uint256 surchargeRate = elapsed >= 1800 ? 0 : (2000 * (1800 - elapsed) / 1800);
        uint256 floored = leg * 425 / 10_000 + (sell ? leg * surchargeRate / 10_000 : 0);
        if (sell) {
            require(charged >= floored && charged - floored <= 2, "sell fee outside rounding allowance");
            if (surchargeRate > 0) require(base == leg * 425 / 10_000, "sell base component");
        } else {
            require(surcharge == 0, "buy surcharge");
            require(charged <= floored && floored - charged <= 1, "buy fee outside rounding allowance");
        }
        if (surchargeRate == 0) require(surcharge == 0, "surcharge after expiry");
    }

    function _poolState(PoolKey memory k) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(k.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(k.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(k.toId())));
    }

    function _accounts() private view returns (address[9] memory) {
        return [
            fixture,
            address(manager),
            address(this),
            address(hook),
            address(router),
            treasury,
            actors[0],
            actors[1],
            actors[2]
        ];
    }

    function economicState() public view returns (bytes32 h) {
        h = keccak256(abi.encode(_poolState(launchKey), _poolState(publicKey), hook.pending()));
        address[9] memory accounts = _accounts();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            h = keccak256(
                abi.encode(
                    h,
                    token.balanceOf(a),
                    IntegrationIMD(IMD).balanceOf(a),
                    a.balance,
                    token.allowance(a, address(router))
                )
            );
        }
    }

    function totals() external view returns (uint256 moneyback, uint256 imd, uint256 eth) {
        address[9] memory accounts = _accounts();
        for (uint256 i; i < accounts.length; ++i) {
            moneyback += token.balanceOf(accounts[i]);
            imd += IntegrationIMD(IMD).balanceOf(accounts[i]);
            eth += accounts[i].balance;
        }
    }

    function assertSettled() public view {
        require(uint256(manager.exttload(Lock.IS_UNLOCKED_SLOT)) == 0, "manager left unlocked");
        require(uint256(manager.exttload(NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT)) == 0, "unsettled currency deltas");
        address[3] memory accounts = [address(this), address(hook), address(router)];
        address[3] memory currencies = [address(0), IMD, address(token)];
        for (uint256 i; i < accounts.length; ++i) {
            for (uint256 j; j < currencies.length; ++j) {
                require(
                    manager.exttload(keccak256(abi.encode(accounts[i], currencies[j]))) == bytes32(0), "residual debt"
                );
            }
        }
    }
}

abstract contract MoneyBackStatefulV4Test is RealV4Environment {
    MoneyBackV4Handler internal handler;
    uint256 private initialEth;
    uint256 private initialImd;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function setUp() public override {
        _boot(false);
        PoolKey memory publicKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        manager.initialize(publicKey, Q96);
        _liquidity(publicKey, -600, 600, LIQUIDITY, 0);
        handler = new MoneyBackV4Handler(IPoolManager(address(manager)), token, hook, router, key);
        token.transfer(address(handler), 1_000_000e18);
        IntegrationIMD(IMD).transfer(address(handler), 1_000_000e18);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            token.transfer(actor, 1_000_000e18);
            vm.deal(actor, 100_000 ether);
        }
        (, initialImd, initialEth) = handler.totals();
    }

    function targetContracts() external view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory s) {
        bytes4[] memory methods = new bytes4[](9);
        methods[0] = handler.swap.selector;
        methods[1] = handler.batchSwap.selector;
        methods[2] = handler.route.selector;
        methods[3] = handler.quote.selector;
        methods[4] = handler.rejectSlippage.selector;
        methods[5] = handler.giftClaims.selector;
        methods[6] = handler.sweep.selector;
        methods[7] = handler.elapse.selector;
        methods[8] = handler.rejectPartialFill.selector;
        s = new FuzzSelector[](1);
        s[0] = FuzzSelector(address(handler), methods);
    }

    function invariant_realClaimBackingAndSettlement() public view {
        require(hook.pending() == handler.accrued() + handler.gifted() - handler.swept(), "claim ledger");
        require(IntegrationIMD(IMD).balanceOf(PAYOUT) == handler.swept(), "immutable payout ledger");
        require(IntegrationIMD(IMD).balanceOf(address(manager)) >= hook.pending(), "unbacked claims");
        require(manager.balanceOf(address(hook), uint256(uint160(address(token)))) == 0, "MONEYBACK claims");
        require(manager.balanceOf(address(hook), 0) == 0, "native fee claims");
        handler.assertSettled();
    }

    function invariant_realAssetConservationAndNoRouterCustody() public view {
        (uint256 moneyback, uint256 imd, uint256 eth) = handler.totals();
        require(moneyback == token.totalSupply() && moneyback == 1_000_000_000e18, "fixed MONEYBACK supply");
        require(imd == initialImd, "IMD conservation");
        require(eth == initialEth, "ETH conservation");
        require(
            token.balanceOf(address(router)) == 0 && IntegrationIMD(IMD).balanceOf(address(router)) == 0,
            "router token residue"
        );
        require(address(router).balance == 0, "router ETH residue");
        require(
            token.balanceOf(address(hook)) == 0 && IntegrationIMD(IMD).balanceOf(address(hook)) == 0,
            "hook should hold claims only"
        );
        require(hook.initializedAt() == T0 && hook.payout() == PAYOUT, "binding changed");
    }

    function test_failedSweepRestoresBurnedClaimsAndCanRetry() public {
        handler.swap(20e18, 0);
        vm.etch(IMD, address(new PayoutBlockingIMD()).code);
        PayoutBlockingIMD(IMD).blockRecipient(PAYOUT);
        // Trading remains possible while the immutable recipient cannot receive IMD.
        handler.swap(10e18, 2);
        uint256 pendingBefore = hook.pending();
        require(pendingBefore > 0, "no claims to redeem");
        bytes32 beforeState = handler.economicState();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                IMD,
                bytes4(keccak256("transfer(address,uint256)")),
                abi.encodeWithSelector(PayoutBlockingIMD.RecipientBlocked.selector, PAYOUT),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.sweep();
        require(hook.pending() == pendingBefore && handler.economicState() == beforeState, "failed sweep burned value");
        handler.assertSettled();
        PayoutBlockingIMD(IMD).blockRecipient(address(0));
        handler.sweep(0);
        invariant_realClaimBackingAndSettlement();
        invariant_realAssetConservationAndNoRouterCustody();
    }

    function test_competingBuyInvalidatesOldQuoteAndSlippageRevertIsAtomic() public {
        uint256 oldQuote = router.quoteBuy(10 ether);
        handler.route(99e18, 1, false);
        uint256 newQuote = router.quoteBuy(10 ether);
        require(newQuote < oldQuote, "competing buy did not move the price");
        bytes32 beforeState = handler.economicState();
        address actor = handler.actors(0);
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, newQuote, oldQuote));
        router.buyWithEth{value: 10 ether}(oldQuote, block.timestamp);
        require(handler.economicState() == beforeState, "stale quote trade retained effects");
        handler.route(uint96(10e18 - 1e12), 0, false);
        invariant_realClaimBackingAndSettlement();
        invariant_realAssetConservationAndNoRouterCustody();
    }

    function test_rejectedEthProceedsRollBackBothPoolsAndTokenPull() public {
        RejectingSeller seller = new RejectingSeller();
        token.transfer(address(seller), 100e18);
        uint256 quoted = router.quoteSell(100e18);
        bytes32 beforeState = handler.economicState();
        uint256 beforeTokens = token.balanceOf(address(seller));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.EthTransferFailed.selector));
        seller.sell(router, token, 100e18, quoted);
        require(handler.economicState() == beforeState, "ETH rejection retained swap effects");
        require(token.balanceOf(address(seller)) == beforeTokens, "rejected recipient lost tokens");
        require(token.allowance(address(seller), address(router)) == 0, "failed outer call retained approval");
        handler.assertSettled();
        seller.setRejectEth(false);
        require(seller.sell(router, token, 100e18, quoted) == quoted, "router guard did not recover");
        require(address(seller).balance == quoted && token.balanceOf(address(seller)) == 0, "seller recovery balances");
        require(address(router).balance == 0 && token.balanceOf(address(router)) == 0, "router recovery residue");
    }

    function testFuzz_repeatedRealRouterRoundTripsCannotCreateValue(uint96 raw, uint16 elapsed, uint8 cycles) public {
        vm.warp(T0 + uint256(elapsed) % 3601);
        uint256 amount = uint256(raw) % 100e18 + 1e12;
        cycles = cycles % 5 + 1;
        token.approve(address(router), type(uint256).max);
        for (uint256 i; i < cycles; ++i) {
            uint256 ethBefore = address(this).balance;
            uint256 tokensBefore = token.balanceOf(address(this));
            uint256 feesBefore = hook.pending();
            uint256 bought = router.buyWithEth{value: amount}(1, block.timestamp);
            uint256 quoteOut = router.quoteSell(bought);
            uint256 paid = router.sellForEth(bought, quoteOut, block.timestamp);
            require(paid == quoteOut && paid < amount, "round trip created ETH");
            require(token.balanceOf(address(this)) == tokensBefore, "round trip retained MONEYBACK");
            require(address(this).balance == ethBefore - amount + paid, "round trip ETH accounting");
            require(hook.pending() > feesBefore, "round trip escaped IMD fees");
            require(address(router).balance == 0 && token.balanceOf(address(router)) == 0, "round trip router residue");
            handler.assertSettled();
        }
    }

    /// @dev Deterministic witness that every selector reaches a meaningful state, including all four
    /// fee paths, gifted claims, quote/revert rollback, repeated sweeps and surcharge expiry.
    function test_sequenceExercisesEveryAction() public {
        handler.batchSwap(10e18, 0);
        handler.route(10e18, 0, false);
        handler.route(5e18, 1, true);
        handler.rejectSlippage(3e18, 2, false);
        handler.rejectSlippage(3e18, 2, true);
        handler.rejectPartialFill(5e18, false);
        handler.rejectPartialFill(5e18, true);
        handler.giftClaims(1e18);
        handler.sweep(2);
        handler.sweep(1);
        for (uint256 i; i < 6; ++i) {
            handler.elapse(300);
        }
        require(hook.currentSurchargeBps() == 0, "time transition not reached");
        handler.batchSwap(1e18, 2);
        for (uint256 i; i < 4; ++i) {
            require(handler.directCalls(i) == 2, "uncovered swap form");
        }
        require(handler.buys() == 1 && handler.sells() == 1 && handler.rejections() == 2, "uncovered router path");
        require(handler.quotes() == 4 && handler.partialRejections() == 2, "uncovered rollback path");
        invariant_realClaimBackingAndSettlement();
        invariant_realAssetConservationAndNoRouterCustody();
    }
}

/// @dev Put inline settings on concrete contracts: Foundry does not inherit the abstract annotations.
/// forge-config: default.fuzz.runs = 1000
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MoneyBackStatefulV4Token0Test is MoneyBackStatefulV4Test {
    function _wantToken0() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Put inline settings on concrete contracts: Foundry does not inherit the abstract annotations.
/// forge-config: default.fuzz.runs = 1000
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MoneyBackStatefulV4Token1Test is MoneyBackStatefulV4Test {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
