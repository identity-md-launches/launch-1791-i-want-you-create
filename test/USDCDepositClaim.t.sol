// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {USDCDepositClaim} from "../src/USDCDepositClaim.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {CallbackWallet} from "./helpers/CallbackWallet.sol";

contract DepositClaimFactory {
    function deploy(address initialOwner) external returns (USDCDepositClaim) {
        return new USDCDepositClaim{salt: keccak256("application")}(initialOwner);
    }
}

contract USDCDepositClaimTest is Test {
    address private constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 private constant FUNDING = 1_000_000e6;
    USDCDepositClaim private escrow;
    MockUSDC private token;
    address private owner;
    address private alice;
    address private bob;
    address private outsider;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        outsider = makeAddr("outsider");
        vm.etch(USDC_ADDRESS, address(new MockUSDC()).code);
        token = MockUSDC(USDC_ADDRESS);
        escrow = new USDCDepositClaim(owner);
        token.mint(owner, FUNDING);
    }

    function test_initialConfiguration() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), address(0));
        assertEq(address(escrow.USDC()), USDC_ADDRESS);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(escrow.claimable(alice), 0);
    }

    function test_factoryDeploysWithExplicitLaunchOwnerOnEmptyChain() public {
        vm.etch(USDC_ADDRESS, "");
        address launchOwner = address(bytes20(hex"ca182aa19dde767ab809e0a4cc9fc1860be03d36"));
        DepositClaimFactory factory = new DepositClaimFactory();
        USDCDepositClaim deployed = factory.deploy(launchOwner);
        assertEq(deployed.owner(), launchOwner);
        assertTrue(deployed.owner() != address(factory));
        assertTrue(address(deployed).code.length > 0);
        assertLe(address(deployed).code.length, 24_576);
    }

    function test_zeroOwnerRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new USDCDepositClaim(address(0));
    }

    function test_runtimeContainsNoForbiddenOpcodesOrLibraryLinks() public view {
        bytes memory code = address(escrow).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function test_oneBaseUnitCanBeFundedAndClaimed() public {
        _deposit(alice, 1);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 1);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_uint256MaximumCanBeFundedAndClaimedWithoutTruncation() public {
        token.mint(owner, type(uint256).max - FUNDING);
        _deposit(alice, type(uint256).max);
        assertEq(escrow.claimable(alice), type(uint256).max);
        assertEq(escrow.totalClaimable(), type(uint256).max);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), type(uint256).max);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_depositPullsFromOwnerAndCreditsRecipient() public {
        vm.startPrank(owner);
        token.approve(address(escrow), 25e6);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit USDCDepositClaim.Deposited(owner, alice, 25e6);
        escrow.deposit(alice, 25e6);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), FUNDING - 25e6);
        assertEq(token.balanceOf(address(escrow)), 25e6);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(owner, address(escrow)), 0);
        assertEq(escrow.claimable(alice), 25e6);
        assertEq(escrow.totalClaimable(), 25e6);
    }

    function test_repeatedDepositsAccumulateAndRecipientsStaySeparate() public {
        _deposit(alice, 10e6);
        _deposit(bob, 20e6);
        _deposit(alice, 5e6);
        assertEq(escrow.claimable(alice), 15e6);
        assertEq(escrow.claimable(bob), 20e6);
        assertEq(escrow.totalClaimable(), 35e6);
        assertEq(token.balanceOf(address(escrow)), 35e6);
    }

    function test_claimPaysCallerAndClearsOnlyTheirBalance() public {
        _deposit(alice, 25e6);
        _deposit(bob, 40e6);
        token.mint(alice, 3e6);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit USDCDepositClaim.Claimed(alice, 25e6);
        escrow.claim();
        assertEq(token.balanceOf(alice), 28e6);
        assertEq(escrow.claimable(alice), 0);
        assertEq(escrow.claimable(bob), 40e6);
        assertEq(escrow.totalClaimable(), 40e6);
        assertEq(token.balanceOf(address(escrow)), 40e6);
        vm.prank(bob);
        escrow.claim();
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_claimTwiceRejectedAndNewDepositCanBeClaimed() public {
        _deposit(alice, 7e6);
        vm.prank(alice);
        escrow.claim();
        vm.prank(alice);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        _deposit(alice, 9e6);
        assertEq(escrow.claimable(alice), 9e6);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 16e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_ownerCanBeRecipientButCannotTakeSomeoneElsesCredit() public {
        _deposit(alice, 7e6);
        vm.prank(owner);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        _deposit(owner, 3e6);
        vm.prank(owner);
        escrow.claim();
        assertEq(token.balanceOf(owner), FUNDING - 7e6);
        assertEq(escrow.claimable(alice), 7e6);
    }

    function test_outsiderCannotDepositEvenWithApproval() public {
        token.mint(outsider, 10e6);
        vm.startPrank(outsider);
        token.approve(address(escrow), 10e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        escrow.deposit(alice, 10e6);
        vm.stopPrank();
        assertEq(token.balanceOf(outsider), 10e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_outsiderCannotClaimAnotherRecipientsFunds() public {
        _deposit(alice, 10e6);
        vm.prank(outsider);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        assertEq(escrow.claimable(alice), 10e6);
        assertEq(token.balanceOf(outsider), 0);
    }

    function test_zeroDepositRejected() public {
        vm.prank(owner);
        vm.expectRevert(USDCDepositClaim.ZeroAmount.selector);
        escrow.deposit(alice, 0);
    }

    function test_invalidRecipientsRejected() public {
        address[3] memory invalid = [address(0), address(escrow), address(token)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(USDCDepositClaim.InvalidRecipient.selector, invalid[i]));
            escrow.deposit(invalid[i], 1);
        }
    }

    function test_missingTokenCodeRejectsFunding() public {
        vm.etch(USDC_ADDRESS, "");
        vm.prank(owner);
        vm.expectRevert(USDCDepositClaim.TokenUnavailable.selector);
        escrow.deposit(alice, 1e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_missingTokenCodePreservesExistingClaims() public {
        _deposit(alice, 1e6);
        vm.etch(USDC_ADDRESS, "");
        vm.prank(alice);
        vm.expectRevert(USDCDepositClaim.TokenUnavailable.selector);
        escrow.claim();
        assertEq(escrow.claimable(alice), 1e6);
        assertEq(escrow.totalClaimable(), 1e6);
    }

    function test_missingOrInsufficientApprovalDoesNotCredit() public {
        vm.startPrank(owner);
        vm.expectRevert(MockUSDC.InsufficientAllowance.selector);
        escrow.deposit(alice, 10e6);
        token.approve(address(escrow), 10e6 - 1);
        vm.expectRevert(MockUSDC.InsufficientAllowance.selector);
        escrow.deposit(alice, 10e6);
        vm.stopPrank();
        assertEq(escrow.claimable(alice), 0);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.balanceOf(owner), FUNDING);
    }

    function test_insufficientOwnerBalanceDoesNotCredit() public {
        vm.startPrank(owner);
        token.approve(address(escrow), FUNDING + 1);
        vm.expectRevert(MockUSDC.InsufficientBalance.selector);
        escrow.deposit(alice, FUNDING + 1);
        vm.stopPrank();
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.allowance(owner, address(escrow)), FUNDING + 1);
    }

    function test_failedTopUpPreservesPriorCredit() public {
        _deposit(alice, 4e6);
        token.setBehavior(MockUSDC.Behavior.ReturnFalse);
        _expectFailedDeposit(_safeERC20Error(), 2e6);
        assertEq(escrow.claimable(alice), 4e6);
        assertEq(escrow.totalClaimable(), 4e6);
        assertEq(token.balanceOf(address(escrow)), 4e6);
    }

    function test_falseReturningTokenRollsBackDepositAndTokenMovement() public {
        token.setBehavior(MockUSDC.Behavior.ReturnFalse);
        _expectFailedDeposit(_safeERC20Error(), 10e6);
        _assertUnfunded();
    }

    function test_invalidReturnDataRollsBackDeposit() public {
        token.setBehavior(MockUSDC.Behavior.InvalidReturn);
        _expectFailedDeposit(_safeERC20Error(), 10e6);
        _assertUnfunded();
    }

    function test_revertingTokenRollsBackDeposit() public {
        token.setBehavior(MockUSDC.Behavior.RevertTransfer);
        _expectFailedDeposit(abi.encodeWithSelector(MockUSDC.TransferReverted.selector), 10e6);
        _assertUnfunded();
    }

    function test_noReturnTokenSupportsDepositAndClaim() public {
        token.setBehavior(MockUSDC.Behavior.NoReturn);
        _deposit(alice, 10e6);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 10e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_inexactDepositsRejectedEvenWithExistingDonation() public {
        token.mint(address(escrow), 100e6);
        MockUSDC.Behavior[3] memory behaviors =
            [MockUSDC.Behavior.ShortTransfer, MockUSDC.Behavior.NoTransfer, MockUSDC.Behavior.ExtraCredit];
        for (uint256 i; i < behaviors.length; ++i) {
            token.setBehavior(behaviors[i]);
            _expectFailedDeposit(
                abi.encodeWithSelector(USDCDepositClaim.UnexpectedTokenBalance.selector), 10e6
            );
            assertEq(escrow.totalClaimable(), 0);
            assertEq(escrow.claimable(alice), 0);
            assertEq(token.balanceOf(address(escrow)), 100e6);
            assertEq(token.balanceOf(owner), FUNDING);
        }
    }

    function test_claimTransferFailuresPreserveCreditAndCanBeRetried() public {
        _deposit(alice, 10e6);
        MockUSDC.Behavior[3] memory behaviors = [
            MockUSDC.Behavior.ReturnFalse, MockUSDC.Behavior.InvalidReturn, MockUSDC.Behavior.RevertTransfer
        ];
        for (uint256 i; i < behaviors.length; ++i) {
            token.setBehavior(behaviors[i]);
            bytes memory expected = behaviors[i] == MockUSDC.Behavior.RevertTransfer
                ? abi.encodeWithSelector(MockUSDC.TransferReverted.selector)
                : _safeERC20Error();
            _expectFailedClaim(expected, 10e6);
        }
        token.setBehavior(MockUSDC.Behavior.Normal);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 10e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_inexactPayoutsCannotEraseCredit() public {
        _deposit(alice, 10e6);
        MockUSDC.Behavior[3] memory behaviors =
            [MockUSDC.Behavior.ShortTransfer, MockUSDC.Behavior.NoTransfer, MockUSDC.Behavior.ExtraCredit];
        for (uint256 i; i < behaviors.length; ++i) {
            token.setBehavior(behaviors[i]);
            _expectFailedClaim(abi.encodeWithSelector(USDCDepositClaim.UnexpectedTokenBalance.selector), 10e6);
        }
    }

    function test_pausedTokenRejectsDepositsAndClaimsWithoutLosingCredit() public {
        _deposit(alice, 10e6);
        token.setPaused(true);
        _expectFailedDeposit(abi.encodeWithSelector(MockUSDC.TokenPaused.selector), 1e6);
        _expectFailedClaim(abi.encodeWithSelector(MockUSDC.TokenPaused.selector), 10e6);
        token.setPaused(false);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 10e6);
    }

    function test_blacklistedRecipientDoesNotBlockOthersAndCanRetryWhenUnblocked() public {
        _deposit(alice, 10e6);
        _deposit(bob, 20e6);
        token.setBlacklisted(alice, true);
        vm.prank(alice);
        vm.expectRevert(MockUSDC.Blacklisted.selector);
        escrow.claim();
        vm.prank(bob);
        escrow.claim();
        assertEq(token.balanceOf(bob), 20e6);
        assertEq(escrow.claimable(alice), 10e6);
        assertEq(escrow.totalClaimable(), 10e6);
        token.setBlacklisted(alice, false);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 10e6);
    }

    function test_blacklistedOwnerCannotFundAndBlacklistedEscrowPreservesCredit() public {
        token.setBlacklisted(owner, true);
        _expectFailedDeposit(abi.encodeWithSelector(MockUSDC.Blacklisted.selector), 10e6);
        _assertUnfunded();
        token.setBlacklisted(owner, false);
        _deposit(alice, 10e6);
        token.setBlacklisted(address(escrow), true);
        _expectFailedDeposit(abi.encodeWithSelector(MockUSDC.Blacklisted.selector), 1e6);
        _expectFailedClaim(abi.encodeWithSelector(MockUSDC.Blacklisted.selector), 10e6);
    }

    function test_directTransfersDoNotAssignCreditOrIncreaseClaimPayout() public {
        vm.prank(owner);
        token.transfer(address(escrow), 8e6);
        assertEq(escrow.totalClaimable(), 0);
        _deposit(alice, 5e6);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 5e6);
        assertEq(token.balanceOf(address(escrow)), 8e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_ownershipTransferRequiresAcceptanceAndUsesNewOwnersFunds() public {
        _deposit(alice, 5e6);
        vm.prank(owner);
        escrow.transferOwnership(bob);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        escrow.deposit(alice, 1e6);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        escrow.acceptOwnership();
        _deposit(alice, 2e6);
        vm.prank(bob);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), bob);
        assertEq(escrow.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        escrow.deposit(alice, 1e6);
        token.mint(bob, 3e6);
        vm.startPrank(bob);
        token.approve(address(escrow), 3e6);
        escrow.deposit(alice, 3e6);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(owner), FUNDING - 7e6);
        assertEq(escrow.claimable(alice), 10e6);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 10e6);
    }

    function test_pendingOwnerCanBeReplacedOrCancelled() public {
        vm.startPrank(owner);
        escrow.transferOwnership(alice);
        escrow.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.acceptOwnership();
        vm.prank(owner);
        escrow.transferOwnership(address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        escrow.acceptOwnership();
        assertEq(escrow.pendingOwner(), address(0));
        assertEq(escrow.owner(), owner);
    }

    function test_nonOwnerCannotNominateOwnerOrRenounce() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        escrow.transferOwnership(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        escrow.renounceOwnership();
        vm.stopPrank();
    }

    function test_ownerCannotRenounce() public {
        vm.prank(owner);
        vm.expectRevert(USDCDepositClaim.OwnershipRenunciationDisabled.selector);
        escrow.renounceOwnership();
        assertEq(escrow.owner(), owner);
    }

    function test_nativeEtherAndUnknownCallsRejected() public {
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        (bool accepted,) = address(escrow).call{value: 1 ether}("");
        assertFalse(accepted);
        (bool unknown,) = address(escrow).call(abi.encodeWithSignature("withdraw(address)", outsider));
        assertFalse(unknown);
    }

    function testFuzz_depositAndClaimConserveFunds(uint96 first, uint96 second, uint96 third) public {
        uint256 a = uint256(first) + 1;
        uint256 b = uint256(second) + 1;
        uint256 c = uint256(third) + 1;
        token.mint(owner, a + b + c);
        _deposit(alice, a);
        _deposit(bob, b);
        _deposit(alice, c);
        assertEq(escrow.claimable(alice), a + c);
        assertEq(escrow.totalClaimable(), a + b + c);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), a + c);
        assertEq(token.balanceOf(address(escrow)), b);
        vm.prank(bob);
        escrow.claim();
        assertEq(token.balanceOf(bob), b);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.balanceOf(owner), FUNDING);
    }

    function testFuzz_reentrancyCannotEnterEitherFunction(bool duringDeposit, bool callDeposit) public {
        (CallbackWallet wallet, USDCDepositClaim target) = _walletEscrow();
        bytes memory attack = callDeposit
            ? abi.encodeCall(target.deposit, (address(wallet), 1e6))
            : abi.encodeCall(target.claim, ());
        wallet.configure(target, attack, false);
        token.setCallback(address(wallet), true, true);
        bytes memory outer = duringDeposit
            ? abi.encodeCall(target.deposit, (address(wallet), 5e6))
            : abi.encodeCall(target.claim, ());
        wallet.execute(address(target), outer);
        assertEq(wallet.callbackCount(), 1);
        assertFalse(wallet.attackSucceeded());
        assertEq(
            wallet.attackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(wallet.observedClaimable(), duringDeposit ? 10e6 : 0);
        assertEq(wallet.observedTotal(), duringDeposit ? 10e6 : 0);
        assertEq(target.claimable(address(wallet)), duringDeposit ? 15e6 : 0);
        assertEq(target.totalClaimable(), duringDeposit ? 15e6 : 0);
        assertEq(token.balanceOf(address(target)), duringDeposit ? 15e6 : 0);
        assertEq(token.balanceOf(address(wallet)), duringDeposit ? 35e6 : 50e6);
    }

    function test_revertingCallbackRestoresClaimAndGuard() public {
        (CallbackWallet wallet, USDCDepositClaim target) = _walletEscrow();
        wallet.configure(target, abi.encodeCall(target.claim, ()), true);
        token.setCallback(address(wallet), true, false);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        wallet.execute(address(target), abi.encodeCall(target.claim, ()));
        assertEq(target.claimable(address(wallet)), 10e6);
        assertEq(target.totalClaimable(), 10e6);
        assertEq(token.balanceOf(address(target)), 10e6);
        token.setCallback(address(wallet), false, false);
        wallet.execute(address(target), abi.encodeCall(target.claim, ()));
        assertEq(target.totalClaimable(), 0);
        assertEq(token.balanceOf(address(wallet)), 50e6);
    }

    function _walletEscrow() private returns (CallbackWallet wallet, USDCDepositClaim target) {
        wallet = new CallbackWallet();
        target = new USDCDepositClaim(address(wallet));
        token.mint(address(wallet), 50e6);
        wallet.execute(address(token), abi.encodeCall(IERC20.approve, (address(target), 50e6)));
        wallet.execute(address(target), abi.encodeCall(target.deposit, (address(wallet), 10e6)));
    }

    function _deposit(address recipient, uint256 amount) private {
        vm.startPrank(owner);
        token.approve(address(escrow), amount);
        escrow.deposit(recipient, amount);
        vm.stopPrank();
    }

    function _expectFailedDeposit(bytes memory reason, uint256 amount) private {
        uint256 balanceBefore = token.balanceOf(owner);
        vm.startPrank(owner);
        token.approve(address(escrow), amount);
        vm.expectRevert(reason);
        escrow.deposit(alice, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), balanceBefore);
        assertEq(token.allowance(owner, address(escrow)), amount);
    }

    function _expectFailedClaim(bytes memory reason, uint256 amount) private {
        vm.prank(alice);
        vm.expectRevert(reason);
        escrow.claim();
        assertEq(escrow.claimable(alice), amount);
        assertEq(escrow.totalClaimable(), amount);
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(alice), 0);
    }

    function _assertUnfunded() private view {
        assertEq(escrow.claimable(alice), 0);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(owner), FUNDING);
    }

    function _safeERC20Error() private pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, USDC_ADDRESS);
    }
}
