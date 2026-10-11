// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackHook, IPoolManager as HookManager} from "../src/MoneyBackHook.sol";
import {MoneyBackToken} from "../src/MoneyBackToken.sol";
import {MoneyBackRouter} from "../src/MoneyBackRouter.sol";
import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "./vendor/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "./vendor/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "./vendor/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";

interface VmRealV4 {
    function etch(address, bytes calldata) external;
    function warp(uint256) external;
    function deal(address, uint256) external;
    function expectRevert(bytes calldata) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
}

interface IERC20RealV4 {
    function transfer(address to, uint256 value) external returns (bool);
}

contract IntegrationIMD {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
}

/// @dev Real v4-core pool math, hooks, claims, locks and settlement; no simulated swap deltas.
///      Inherited twice to exercise both actual sorted currency orders with the real launch token.
abstract contract RealV4Fixture is IUnlockCallback {
    using StateLibrary for IPoolManager;

    VmRealV4 constant vm = VmRealV4(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PAYOUT = address(0xBACC);
    uint160 constant Q96 = 1 << 96;
    uint256 constant T0 = 1_750_000_000;
    int256 constant LIQUIDITY = 1e24;

    PoolManager manager;
    MoneyBackToken token;
    MoneyBackHook hook;
    MoneyBackRouter router;
    PoolKey key;
    bool tokenIs0;

    function _wantToken0() internal pure virtual returns (bool);

    function setUp() public virtual {
        _boot(false);
    }

    function _boot(bool singleSided) internal {
        vm.warp(T0);
        vm.deal(address(this), 1e30);
        vm.etch(IMD, address(new IntegrationIMD()).code);
        IntegrationIMD(IMD).mint(address(this), 1e30);
        manager = new PoolManager(address(this));
        bytes32 tokenHash = keccak256(type(MoneyBackToken).creationCode);
        for (uint256 salt; salt < 1000; ++salt) {
            address predicted = _predict(bytes32(salt), tokenHash);
            if ((predicted < IMD) == _wantToken0() && predicted.code.length == 0) {
                token = new MoneyBackToken{salt: bytes32(salt)}();
                break;
            }
        }
        require(address(token) != address(0), "token salt");
        tokenIs0 = address(token) < IMD;
        require(tokenIs0 == _wantToken0(), "sorted token order");
        bytes32 hookHash = keccak256(
            abi.encodePacked(type(MoneyBackHook).creationCode, abi.encode(address(manager), address(token), PAYOUT))
        );
        for (uint256 salt; salt < 1_000_000; ++salt) {
            if (uint160(_predict(bytes32(salt), hookHash)) & 0x3FFF == 0x20CC) {
                hook = new MoneyBackHook{salt: bytes32(salt)}(HookManager(address(manager)), address(token), PAYOUT);
                break;
            }
        }
        require(address(hook) != address(0), "hook salt");
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : IMD),
            currency1: Currency.wrap(tokenIs0 ? IMD : address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, Q96);
        router = new MoneyBackRouter(HookManager(address(manager)), address(hook));
        if (singleSided) {
            _liquidity(key, tokenIs0 ? int24(0) : int24(-600), tokenIs0 ? int24(600) : int24(0), LIQUIDITY, 0);
        } else {
            _liquidity(key, -600, 600, LIQUIDITY, 0);
        }
    }

    function _predict(bytes32 salt, bytes32 codeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function _params(bool sell, bool exactInput, uint256 amount, bool tight)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = sell == tokenIs0;
        p.amountSpecified = exactInput ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = tight
            ? (p.zeroForOne ? Q96 - Q96 / 100_000 : Q96 + Q96 / 100_000)
            : (p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _trade(SwapParams memory p) internal returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(p))), (BalanceDelta));
    }

    function _liquidity(PoolKey memory k, int24 lower, int24 upper, int256 amount, bytes32 salt)
        internal
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), k, abi.encode(ModifyLiquidityParams(lower, upper, amount, salt)))),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory k, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(k, abi.decode(params, (SwapParams)), "");
        } else {
            (delta,) = manager.modifyLiquidity(k, abi.decode(params, (ModifyLiquidityParams)), "");
        }
        _settle(k.currency0, delta.amount0());
        _settle(k.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                require(IERC20RealV4(Currency.unwrap(currency)).transfer(address(manager), amount), "settle transfer");
                manager.settle();
            }
        }
    }

    receive() external payable {}

    function _imd(BalanceDelta delta) internal view returns (int256) {
        return tokenIs0 ? delta.amount1() : delta.amount0();
    }

    function _moneyback(BalanceDelta delta) internal view returns (int256) {
        return tokenIs0 ? delta.amount0() : delta.amount1();
    }

    function _fee(bool sell, uint256 leg) internal view returns (uint256) {
        return leg * 425 / 10_000 + (sell ? leg * hook.currentSurchargeBps() / 10_000 : 0);
    }

    /// @dev Assert the fee against the observed pool leg, without using the inverse pricing formula.
    function _assertPoolLegFee(bool sell, bool specified, uint256 leg, uint256 charged) internal view {
        uint256 floored = _fee(sell, leg);
        if (!specified) {
            require(charged == floored, "actual pool delta fee");
        } else if (sell) {
            require(charged >= floored && charged - floored <= 2, "sell gross-up rounding bound");
            uint256 numerator = leg * (425 + hook.currentSurchargeBps());
            require(charged * 10_000 >= numerator && charged * 10_000 - numerator < 10_000, "sell pool-leg rate");
        } else {
            require(charged <= floored && floored - charged <= 1, "buy rounding bound");
        }
    }

    function _assertEquivalentTrades(bool sell, uint256 amount) internal {
        uint256 snap = vm.snapshotState();
        uint256 beforeFee = hook.pending();
        BalanceDelta first = _trade(_params(sell, !sell, amount, false));
        uint256 firstFee = hook.pending() - beforeFee;
        uint256 firstPoolLeg = sell ? uint256(_imd(first)) + firstFee : uint256(-_imd(first)) - firstFee;
        uint256 tokenAmount = uint256(sell ? -_moneyback(first) : _moneyback(first));
        require(_imd(first) == (sell ? int256(amount) : -int256(amount)), "specified IMD exact");
        _assertPoolLegFee(sell, true, firstPoolLeg, firstFee);

        require(vm.revertToState(snap), "snapshot restored");
        BalanceDelta second = _trade(_params(sell, sell, tokenAmount, false));
        uint256 secondFee = hook.pending() - beforeFee;
        uint256 secondPoolLeg = sell ? uint256(_imd(second)) + secondFee : uint256(-_imd(second)) - secondFee;
        require(_moneyback(first) == _moneyback(second), "same MONEYBACK movement");
        require(firstPoolLeg + 2 >= secondPoolLeg && secondPoolLeg + 2 >= firstPoolLeg, "same pool IMD movement");
        _assertPoolLegFee(sell, false, secondPoolLeg, secondFee);
        // Inverse fee rounding (at most 2) plus v4's pool/LP rounding (at most 1 fee unit).
        require(firstFee + 3 >= secondFee && secondFee + 3 >= firstFee, "same fee independent of swap form");
    }

    function test_equivalentBuysAndSellsAtDecayBoundaries() public {
        uint256[5] memory elapsed = [uint256(0), 900, 1799, 1800, 3600];
        for (uint256 i; i < elapsed.length; ++i) {
            vm.warp(T0 + elapsed[i]);
            _assertEquivalentTrades(false, 100e18);
            _assertEquivalentTrades(true, 100e18);
        }
    }

    function testFuzz_equivalentSwapForms(uint96 raw, uint32 elapsed, bool sell) public {
        vm.warp(T0 + uint256(elapsed) % 3601);
        _assertEquivalentTrades(sell, uint256(raw) % 1000e18 + 1e12);
    }

    function test_routerUnfillableBuyAndQuoteRevertAtomically() public {
        PoolKey memory publicKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        manager.initialize(publicKey, Q96);
        _liquidity(publicKey, -600, 600, 1e27, 0);
        uint256 smallQuote = router.quoteBuy(1 ether);
        require(smallQuote > 0, "ordinary quote succeeds");
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(MoneyBackHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(expected);
        router.quoteBuy(100_000 ether);
        vm.expectRevert(expected);
        router.buyWithEth{value: 100_000 ether}(1, block.timestamp);
        require(address(this).balance == ethBefore && token.balanceOf(address(this)) == tokensBefore, "no funds moved");
        require(hook.pending() == 0, "no claims retained");
        (uint160 launchPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 publicPrice,,,) = IPoolManager(address(manager)).getSlot0(publicKey.toId());
        require(launchPrice == Q96 && publicPrice == Q96, "both pools rolled back");
        require(
            router.buyWithEth{value: 1 ether}(smallQuote, block.timestamp) == smallQuote, "router usable after revert"
        );
    }

    function test_fullFillAllFourCasesAndSweep() public {
        for (uint256 elapsed; elapsed <= 1800; elapsed += 900) {
            vm.warp(T0 + elapsed);
            for (uint256 c; c < 4; ++c) {
                bool sell = c >= 2;
                bool exactInput = c % 2 == 0;
                uint256 beforeFee = hook.pending();
                BalanceDelta delta = _trade(_params(sell, exactInput, 100e18, false));
                uint256 charged = hook.pending() - beforeFee;
                int256 imdDelta = _imd(delta);
                require(sell ? imdDelta > 0 : imdDelta < 0, "IMD direction");
                require(sell ? _moneyback(delta) < 0 : _moneyback(delta) > 0, "MONEYBACK direction");
                if (sell != exactInput) {
                    require(imdDelta == (sell ? int256(100e18) : -int256(100e18)), "full specified amount");
                }
                uint256 poolLeg = sell ? uint256(imdDelta) + charged : uint256(-imdDelta) - charged;
                _assertPoolLegFee(sell, sell != exactInput, poolLeg, charged);
            }
        }
        uint256 pending = hook.pending();
        uint256 beforePayout = IntegrationIMD(IMD).balanceOf(PAYOUT);
        hook.sweep();
        require(hook.pending() == 0, "claims burned");
        require(IntegrationIMD(IMD).balanceOf(PAYOUT) - beforePayout == pending, "immutable wallet paid IMD");
    }

    function _assertPartialReverts(SwapParams memory params) internal {
        uint256 imdBefore = IntegrationIMD(IMD).balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 pending = hook.pending();
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(MoneyBackHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.unlock(abi.encode(uint8(0), key, abi.encode(params)));
        require(IntegrationIMD(IMD).balanceOf(address(this)) == imdBefore, "IMD changed on revert");
        require(token.balanceOf(address(this)) == tokenBefore, "tokens changed on revert");
        require(hook.pending() == pending, "fee survived revert");
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        require(priceAfter == priceBefore, "pool price changed on revert");
    }

    function test_exactOutputSellTightLimitRevertsWithoutTakingIMD() public {
        _assertPartialReverts(_params(true, false, 100e18, true));
    }

    function test_exactInputBuyTightLimitRevertsWithoutOvercharge() public {
        _assertPartialReverts(_params(false, true, 100e18, true));
    }

    function test_exactOutputSellExhaustedLiquidityReverts() public {
        _assertPartialReverts(_params(true, false, 100_000e18, false));
    }

    function test_exactInputBuyExhaustedLiquidityReverts() public {
        _assertPartialReverts(_params(false, true, 100_000e18, false));
    }

    function test_partialUnspecifiedIMDStillChargesActualFill() public {
        // Exact-input sell may fill partially: its IMD fee uses only the actual output.
        uint256 beforeFee = hook.pending();
        BalanceDelta delta = _trade(_params(true, true, 100_000e18, false));
        uint256 charged = hook.pending() - beforeFee;
        require(_moneyback(delta) > -int256(100_000e18), "fixture did not underfill");
        require(_imd(delta) > 0, "seller must receive IMD");
        require(charged == _fee(true, uint256(_imd(delta)) + charged), "fee on actual sell output");
    }

    function test_partialExactOutputBuyChargesActualIMD() public {
        BalanceDelta delta = _trade(_params(false, false, 100_000e18, false));
        require(_moneyback(delta) > 0 && _moneyback(delta) < int256(100_000e18), "partial output");
        require(hook.pending() == _fee(false, uint256(-_imd(delta)) - hook.pending()), "actual buy fee");
    }

    function test_freshSingleSidedPoolCanBuyAndSweepWithNoIMDReserve() public {
        _boot(true);
        require(IntegrationIMD(IMD).balanceOf(address(manager)) == 0, "pool must start without IMD");
        BalanceDelta delta = _trade(_params(false, true, 100e18, false));
        require(_imd(delta) == -int256(100e18) && _moneyback(delta) > 0, "single sided buy");
        uint256 fee = hook.pending();
        require(fee > 0, "claim accrued before router settled");
        _assertPoolLegFee(false, true, 100e18 - fee, fee);
        uint256 beforePayout = IntegrationIMD(IMD).balanceOf(PAYOUT);
        hook.sweep();
        require(hook.pending() == 0, "claim redeemed");
        require(IntegrationIMD(IMD).balanceOf(PAYOUT) - beforePayout == fee, "fee remains IMD");
    }

    function test_singleSidedPoolRejectsUnfillableExactOutputSell() public {
        _boot(true);
        _assertPartialReverts(_params(true, false, 100e18, false));
    }

    function test_liquidityConversionIsOutsideSwapSurcharge() public {
        int24 lower = tokenIs0 ? int24(60) : int24(-120);
        int24 upper = tokenIs0 ? int24(120) : int24(-60);
        BalanceDelta deposited = _liquidity(key, lower, upper, 100_000e18, bytes32(uint256(1)));
        require(_moneyback(deposited) < 0 && _imd(deposited) == 0, "single sided LP deposit");
        require(hook.pending() == 0, "LP deposit has no swap fee");
        _trade(_params(false, true, 10_000e18, false));
        uint256 buyersFee = hook.pending();
        _assertPoolLegFee(false, true, 10_000e18 - buyersFee, buyersFee);
        BalanceDelta withdrawn = _liquidity(key, lower, upper, -100_000e18, bytes32(uint256(1)));
        require(_moneyback(withdrawn) == 0 && _imd(withdrawn) > 0, "LP converted token to IMD");
        require(hook.pending() == buyersFee, "LP withdrawal does not pay surcharge");
        require(hook.currentSurchargeBps() == 2000, "still inside surcharge window");
    }

    function test_routerTradesAgainstRealManagerAndRefundsPartialSell() public {
        PoolKey memory publicKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        manager.initialize(publicKey, Q96);
        _liquidity(publicKey, -600, 600, LIQUIDITY, 0);
        uint256 quoted = router.quoteBuy(100 ether);
        uint256 beforeTokens = token.balanceOf(address(this));
        uint256 received = router.buyWithEth{value: 100 ether}(quoted, block.timestamp);
        require(received == quoted && token.balanceOf(address(this)) - beforeTokens == quoted, "buy quote and balance");
        token.approve(address(router), 100_000e18);
        uint256 sellQuote = router.quoteSell(100_000e18);
        beforeTokens = token.balanceOf(address(this));
        uint256 beforeEth = address(this).balance;
        uint256 paid = router.sellForEth(100_000e18, sellQuote, block.timestamp);
        uint256 sold = beforeTokens - token.balanceOf(address(this));
        require(paid == sellQuote && address(this).balance - beforeEth == paid, "sell quote and ETH");
        require(sold > 0 && sold < 100_000e18, "unused tokens refunded");
        require(token.balanceOf(address(router)) == 0, "router token balance");
        require(IntegrationIMD(IMD).balanceOf(address(router)) == 0, "router IMD balance");
        require(address(router).balance == 0, "router ETH balance");
        require(hook.pending() > 0, "fees remain IMD claims");
    }

    function testFuzz_fullFillSpecifiedFee(uint96 raw, uint32 elapsed, bool sell) public {
        uint256 amount = uint256(raw) % 1000e18 + 1e12;
        vm.warp(T0 + uint256(elapsed) % 3601);
        BalanceDelta delta = _trade(_params(sell, !sell, amount, false));
        require(_imd(delta) == (sell ? int256(amount) : -int256(amount)), "specified fill");
        uint256 fee = hook.pending();
        _assertPoolLegFee(sell, true, sell ? amount + fee : amount - fee, fee);
    }
}

contract MoneyBackRealV4Token0Test is RealV4Fixture {
    function _wantToken0() internal pure override returns (bool) {
        return true;
    }
}

contract MoneyBackRealV4Token1Test is RealV4Fixture {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
