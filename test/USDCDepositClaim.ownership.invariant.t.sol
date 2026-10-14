// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {USDCDepositClaim} from "src/USDCDepositClaim.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @dev A closed economy: mint only in construction, then circulate a fixed supply.
/// Every actor can be both owner and recipient. The model uses action inputs, never
/// the application's balances, to decide who owns what and which calls should fail.
contract OwnershipAccountingHandler is Test {
    uint256 public constant ACTOR_COUNT = 4;
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;
    MockUSDC public immutable token;
    USDCDepositClaim public immutable escrow;
    address[4] public actors;
    address public expectedOwner;
    address public expectedPendingOwner;

    mapping(address => uint256) public fundedFor;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public spentFunding;
    mapping(address => uint256) public donatedBy;
    uint256 public totalFunded;
    uint256 public totalPaid;
    uint256 public totalDonated;
    uint256 public acceptedHandovers;

    constructor(MockUSDC token_) {
        token = token_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("ownership model actor ", vm.toString(i)));
            token.mint(actors[i], INITIAL_BALANCE);
        }
        expectedOwner = actors[0];
        escrow = new USDCDepositClaim(expectedOwner);
    }

    function expectedCash(address actor) public view returns (uint256) {
        return INITIAL_BALANCE + paid[actor] - spentFunding[actor] - donatedBy[actor];
    }

    function deposit(uint256 recipientSeed, uint256 amountSeed) public {
        address recipient = actors[recipientSeed % ACTOR_COUNT];
        uint256 available = expectedCash(expectedOwner);
        uint256 amount = bound(amountSeed, 1, available == 0 ? 1 : available);
        vm.startPrank(expectedOwner);
        token.approve(address(escrow), amount);
        if (available == 0) vm.expectRevert(MockUSDC.InsufficientBalance.selector);
        escrow.deposit(recipient, amount);
        vm.stopPrank();
        if (available == 0) {
            assertEq(token.allowance(expectedOwner, address(escrow)), amount, "failed pull spent allowance");
        } else {
            fundedFor[recipient] += amount;
            spentFunding[expectedOwner] += amount;
            totalFunded += amount;
            assertEq(token.allowance(expectedOwner, address(escrow)), 0, "wrong funding allowance");
        }
    }

    function claim(uint256 actorSeed) public {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 amount = fundedFor[actor] - paid[actor];
        vm.prank(actor);
        if (amount == 0) vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        paid[actor] += amount;
        totalPaid += amount;
        assertEq(escrow.claimable(actor), 0, "successful claim left credit");
    }

    function donate(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 amount = bound(amountSeed, 0, expectedCash(actor));
        vm.prank(actor);
        token.transfer(address(escrow), amount);
        donatedBy[actor] += amount;
        totalDonated += amount;
    }

    function nominate(uint256 candidateSeed) public {
        // The fifth choice cancels a nomination. Self-nomination is also reachable.
        uint256 choice = candidateSeed % (ACTOR_COUNT + 1);
        address candidate = choice == ACTOR_COUNT ? address(0) : actors[choice];
        vm.prank(expectedOwner);
        escrow.transferOwnership(candidate);
        expectedPendingOwner = candidate;
    }

    function accept(uint256 actorSeed, bool selectPending) public {
        address actor = selectPending && expectedPendingOwner != address(0)
            ? expectedPendingOwner
            : actors[actorSeed % ACTOR_COUNT];
        bool authorized = actor == expectedPendingOwner;
        vm.prank(actor);
        if (!authorized) vm.expectRevert(_unauthorized(actor));
        escrow.acceptOwnership();
        if (authorized) {
            expectedOwner = actor;
            expectedPendingOwner = address(0);
            acceptedHandovers++;
        }
    }

    function unauthorizedDeposit(uint256 actorSeed, uint256 recipientSeed, uint256 amountSeed) public {
        address actor = _nonOwner(actorSeed);
        uint256 available = expectedCash(actor);
        uint256 amount = bound(amountSeed, 1, available == 0 ? 1 : available);
        vm.startPrank(actor);
        token.approve(address(escrow), amount);
        vm.expectRevert(_unauthorized(actor));
        escrow.deposit(actors[recipientSeed % ACTOR_COUNT], amount);
        vm.stopPrank();
        assertEq(token.allowance(actor, address(escrow)), amount, "unauthorized pull consumed approval");
    }

    function unauthorizedAdmin(uint256 actorSeed, uint256 candidateSeed, bool renounce) public {
        address actor = _nonOwner(actorSeed);
        vm.prank(actor);
        vm.expectRevert(_unauthorized(actor));
        if (renounce) escrow.renounceOwnership();
        else escrow.transferOwnership(actors[candidateSeed % ACTOR_COUNT]);
    }

    function failedDeposit(uint256 recipientSeed, uint256 amountSeed, uint256 failureSeed) public {
        uint256 available = expectedCash(expectedOwner);
        uint256 amount = bound(amountSeed, 1, available == 0 ? 1 : available);
        uint256 allowance = amount;
        bytes memory reason;
        uint256 mode = failureSeed % 8;
        if (mode == 0) {
            allowance = amount - 1;
            reason = abi.encodeWithSelector(MockUSDC.InsufficientAllowance.selector);
        } else if (mode == 1 || available == 0) {
            amount = available + 1;
            allowance = amount;
            reason = abi.encodeWithSelector(MockUSDC.InsufficientBalance.selector);
        } else if (mode == 7) {
            amount = 0;
            reason = abi.encodeWithSelector(USDCDepositClaim.ZeroAmount.selector);
        } else {
            reason = _enableFault(mode - 2, expectedOwner);
        }
        vm.startPrank(expectedOwner);
        token.approve(address(escrow), allowance);
        vm.expectRevert(reason);
        escrow.deposit(actors[recipientSeed % ACTOR_COUNT], amount);
        vm.stopPrank();
        assertEq(token.allowance(expectedOwner, address(escrow)), allowance, "failed deposit spent approval");
        _clearFault(expectedOwner);
    }

    function failedClaim(uint256 actorSeed, uint256 failureSeed) public {
        address actor = actors[actorSeed % ACTOR_COUNT];
        bytes memory reason = _enableFault(failureSeed % 5, actor);
        if (fundedFor[actor] == paid[actor]) {
            reason = abi.encodeWithSelector(USDCDepositClaim.NothingToClaim.selector);
        }
        vm.prank(actor);
        vm.expectRevert(reason);
        escrow.claim();
        _clearFault(actor);
    }

    function _enableFault(uint256 mode, address account) private returns (bytes memory reason) {
        if (mode == 0) {
            token.setBehavior(MockUSDC.Behavior.ReturnFalse);
            return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token));
        }
        if (mode == 1 || mode == 2) {
            token.setBehavior(mode == 1 ? MockUSDC.Behavior.ShortTransfer : MockUSDC.Behavior.NoTransfer);
            return abi.encodeWithSelector(USDCDepositClaim.UnexpectedTokenBalance.selector);
        }
        if (mode == 3) {
            token.setPaused(true);
            return abi.encodeWithSelector(MockUSDC.TokenPaused.selector);
        }
        token.setBlacklisted(account, true);
        return abi.encodeWithSelector(MockUSDC.Blacklisted.selector);
    }

    function _clearFault(address account) private {
        token.setBehavior(MockUSDC.Behavior.Normal);
        token.setPaused(false);
        token.setBlacklisted(account, false);
    }

    function _nonOwner(uint256 seed) private view returns (address actor) {
        uint256 index = seed % ACTOR_COUNT;
        actor = actors[index];
        if (actor == expectedOwner) actor = actors[(index + 1) % ACTOR_COUNT];
    }

    function _unauthorized(address actor) private pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract USDCDepositClaimOwnershipInvariantTest is StdInvariant, Test {
    MockUSDC private token;
    USDCDepositClaim private escrow;
    OwnershipAccountingHandler private handler;

    function setUp() public {
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        vm.etch(usdc, address(new MockUSDC()).code);
        token = MockUSDC(usdc);
        handler = new OwnershipAccountingHandler(token);
        escrow = handler.escrow();
        // Start with four live credits, including the owner, so failures and claims
        // can reach funded paths even before the fuzzer first selects a deposit.
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, (i + 1) * 1e6);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.nominate.selector;
        selectors[4] = handler.accept.selector;
        selectors[5] = handler.unauthorizedDeposit.selector;
        selectors[6] = handler.unauthorizedAdmin.selector;
        selectors[7] = handler.failedDeposit.selector;
        selectors[8] = handler.failedClaim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_onlyAcceptedNomineesBecomeOwner() public view {
        assertEq(escrow.owner(), handler.expectedOwner(), "owner disagrees with accepted handovers");
        assertEq(escrow.pendingOwner(), handler.expectedPendingOwner(), "nomination changed unexpectedly");
    }

    function invariant_everyWalletKeepsItsOwnFundsAndCredits() public view {
        uint256 liability;
        uint256 cash = token.balanceOf(address(escrow));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertLe(handler.paid(actor), handler.fundedFor(actor), "wallet claimed unallocated funds");
            uint256 owed = handler.fundedFor(actor) - handler.paid(actor);
            assertEq(escrow.claimable(actor), owed, "handover or failure changed recipient credit");
            assertEq(token.balanceOf(actor), handler.expectedCash(actor), "wrong wallet funded or received");
            liability += owed;
            cash += token.balanceOf(actor);
        }
        assertEq(escrow.totalClaimable(), liability, "total liability differs from individual credits");
        assertEq(handler.totalFunded(), handler.totalPaid() + liability, "funding is not conserved");
        assertEq(token.balanceOf(address(escrow)), liability + handler.totalDonated(), "incorrect backing");
        assertEq(cash, 4 * handler.INITIAL_BALANCE(), "tokens escaped the closed economy");
        assertEq(token.totalSupply(), cash, "token movement changed supply");
    }

    function afterInvariant() public {
        // Withdrawal liveness must hold even when nomination is pending and after
        // arbitrary failures. No owner intervention or new funding is needed.
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        invariant_onlyAcceptedNomineesBecomeOwner();
        invariant_everyWalletKeepsItsOwnFundsAndCredits();
        assertEq(escrow.totalClaimable(), 0, "a funded wallet could not exit");
        assertEq(handler.totalPaid(), handler.totalFunded(), "not all allocations were redeemable");
    }

    function test_handlerExercisesEveryFailureAndOwnershipTransition() public {
        for (uint256 i; i < 8; ++i) {
            handler.failedDeposit(1, 11e6, i);
            invariant_everyWalletKeepsItsOwnFundsAndCredits();
        }
        for (uint256 i; i < 5; ++i) {
            handler.failedClaim(2, i);
            invariant_everyWalletKeepsItsOwnFundsAndCredits();
        }
        handler.nominate(1);
        handler.unauthorizedDeposit(1, 2, 12e6);
        handler.accept(2, false); // Wrong nominee cannot accept.
        handler.nominate(2); // Replacement invalidates the previous nominee.
        handler.accept(1, false);
        handler.accept(2, true);
        handler.unauthorizedDeposit(0, 1, 13e6); // Former owner still has tokens and approvals.
        handler.unauthorizedAdmin(0, 0, false);
        handler.unauthorizedAdmin(0, 0, true);
        handler.deposit(0, 14e6);
        handler.deposit(2, 15e6); // New owner is also a recipient.
        handler.nominate(3);
        handler.nominate(4); // Cancel.
        handler.accept(3, false);
        handler.nominate(2); // Self-nomination and acceptance.
        handler.accept(2, true);
        handler.donate(3, 16e6);
        assertEq(handler.acceptedHandovers(), 2);
        afterInvariant();
        handler.claim(0); // A second claim must fail even with surplus in escrow.
        handler.deposit(1, 1);
        afterInvariant();
    }

    function test_handlerExercisesExhaustedOwnerAndFullBalanceDeposit() public {
        handler.deposit(1, type(uint256).max);
        handler.deposit(2, 1);
        handler.failedDeposit(3, 1, 2);
        invariant_everyWalletKeepsItsOwnFundsAndCredits();
        handler.claim(0); // Replenish the owner's cash from its own allocation.
        handler.deposit(3, type(uint256).max);
        afterInvariant();
    }
}
