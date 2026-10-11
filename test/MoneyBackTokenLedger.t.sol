// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackToken} from "src/MoneyBackToken.sol";

interface VmLedger {
    function prank(address) external;
}

/// @dev An independent per-account and per-allowance ledger detects value moving to the wrong
/// actor even when aggregate supply still matches. Rejected calls check rollback of *all* entries.
contract TokenLedgerHandler {
    VmLedger private constant vm = VmLedger(address(uint160(uint256(keccak256("hevm cheat code")))));
    MoneyBackToken public immutable token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;
    uint256 public transfers;
    uint256 public spends;
    uint256 public rejected;

    constructor() {
        token = new MoneyBackToken();
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("ledger actor", i)))));
            balances[i] = token.totalSupply() / 4;
            token.transfer(actors[i], balances[i]);
        }
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount, bool infinite) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        amount = infinite ? type(uint256).max : amount;
        vm.prank(actors[owner]);
        require(token.approve(actors[spender], amount), "approve failed");
        allowances[owner][spender] = amount;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 raw, bool full) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = full ? balances[from] : raw % (balances[from] + 1);
        vm.prank(actors[from]);
        require(token.transfer(actors[to], amount), "transfer failed");
        balances[from] -= amount;
        balances[to] += amount;
        transfers++;
    }

    function spend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 raw, bool full) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 cap = allowances[owner][spender];
        if (cap > balances[owner]) cap = balances[owner];
        uint256 amount = full ? cap : raw % (cap + 1);
        vm.prank(actors[spender]);
        require(token.transferFrom(actors[owner], actors[to], amount), "transferFrom failed");
        balances[owner] -= amount;
        balances[to] += amount;
        if (allowances[owner][spender] != type(uint256).max) allowances[owner][spender] -= amount;
        spends++;
    }

    function rejectSpend(uint8 ownerSeed, uint8 spenderSeed, uint8 mode) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        mode %= 3;
        uint256 amount;
        address to = actors[(owner + 1) % 4];
        bytes memory expected;
        if (mode == 0) {
            // Enough allowance, insufficient balance: allowance debit must roll back too.
            amount = balances[owner] + 1;
            approve(ownerSeed, spenderSeed, amount, false);
            expected = abi.encodeWithSelector(
                MoneyBackToken.ERC20InsufficientBalance.selector, actors[owner], balances[owner], amount
            );
        } else if (mode == 1) {
            // Spending after explicit revocation must fail, even for the owner as spender.
            approve(ownerSeed, spenderSeed, 0, false);
            amount = 1;
            expected =
                abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, actors[spender], 0, amount);
        } else {
            amount = balances[owner];
            approve(ownerSeed, spenderSeed, amount, false);
            to = address(0);
            expected = abi.encodeWithSelector(MoneyBackToken.ERC20InvalidReceiver.selector, address(0));
        }
        bytes32 beforeState = stateHash();
        vm.prank(actors[spender]);
        (bool ok, bytes memory reason) =
            address(token).call(abi.encodeCall(token.transferFrom, (actors[owner], to, amount)));
        require(!ok && keccak256(reason) == keccak256(expected), "wrong rejected-spend outcome");
        require(stateHash() == beforeState, "failed transferFrom consumed balance or allowance");
        rejected++;
    }

    function stateHash() public view returns (bytes32 h) {
        h = keccak256(abi.encode(token.totalSupply(), token.balanceOf(address(0)), token.balanceOf(address(this))));
        for (uint256 i; i < 4; ++i) {
            h = keccak256(abi.encode(h, token.balanceOf(actors[i])));
            for (uint256 j; j < 4; ++j) {
                h = keccak256(abi.encode(h, token.allowance(actors[i], actors[j])));
            }
        }
    }

    function assertLedger() external view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            require(token.balanceOf(actors[i]) == balances[i], "individual balance differs from ledger");
            sum += balances[i];
            for (uint256 j; j < 4; ++j) {
                require(token.allowance(actors[i], actors[j]) == allowances[i][j], "allowance differs from ledger");
            }
        }
        require(sum == 1_000_000_000e18 && token.totalSupply() == sum, "supply changed");
        require(token.balanceOf(address(0)) == 0 && token.balanceOf(address(this)) == 0, "untracked balance");
    }
}

contract MoneyBackTokenLedgerTest {
    TokenLedgerHandler internal handler;

    function setUp() public {
        handler = new TokenLedgerHandler();
    }

    function targetContracts() external view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_individualBalancesAndAllowancesMatchLedger() public view {
        handler.assertLedger();
    }

    function test_fullBalanceSelfTransferAndInfiniteAllowanceSequence() public {
        handler.approve(0, 1, 0, true);
        handler.spend(0, 1, 0, 0, true); // Full self-transfer consumes no infinite allowance.
        handler.spend(0, 1, 2, 0, true); // Drain owner through the same approval.
        handler.rejectSpend(0, 1, 0); // Sufficient allowance but owner is now empty.
        handler.transfer(2, 0, 0, true); // Refill from a different actor.
        handler.approve(0, 1, 0, false);
        handler.rejectSpend(0, 1, 1); // Revoked allowance cannot be revived by a new balance.
        handler.rejectSpend(0, 1, 2); // Zero receiver rolls back finite allowance consumption.
        handler.assertLedger();
        require(handler.spends() == 2 && handler.rejected() == 3, "sequence did not exercise expected paths");
    }
}
