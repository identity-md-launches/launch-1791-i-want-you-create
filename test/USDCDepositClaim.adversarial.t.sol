// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {USDCDepositClaim} from "src/USDCDepositClaim.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {CallbackWallet} from "./helpers/CallbackWallet.sol";

/// @dev An intermediary deliberately changes msg.sender while retaining tx.origin.
contract EscrowCallRelay {
    function claim(USDCDepositClaim escrow) external {
        escrow.claim();
    }

    function deposit(USDCDepositClaim escrow, address recipient, uint256 amount) external {
        escrow.deposit(recipient, amount);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract USDCDepositClaimAdversarialTest is Test {
    address private constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    MockUSDC private token;
    USDCDepositClaim private escrow;
    address private owner;
    address private alice;
    address private bob;

    function setUp() public {
        owner = makeAddr("adversarial owner");
        alice = makeAddr("adversarial alice");
        bob = makeAddr("adversarial bob");
        vm.etch(USDC_ADDRESS, address(new MockUSDC()).code);
        token = MockUSDC(USDC_ADDRESS);
        escrow = new USDCDepositClaim(owner);
    }

    function testFuzz_arbitraryCreditedWalletExclusivelyReceivesItsFunds(address recipient, uint128 seed)
        public
    {
        // Map only invalid recipients, keeping the rest of the address domain.
        if (recipient == address(0) || recipient == address(escrow) || recipient == USDC_ADDRESS) {
            recipient = bob;
        }
        uint256 amount = uint256(seed) + 1;
        token.mint(owner, amount);
        _deposit(recipient, amount);

        address thief = recipient == alice ? bob : alice;
        vm.prank(thief);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        assertEq(escrow.claimable(recipient), amount);
        assertEq(token.balanceOf(thief), 0);

        vm.prank(recipient);
        escrow.claim();
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.claimable(recipient), 0);
        assertEq(escrow.totalClaimable(), 0);
        vm.prank(recipient);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
    }

    function testFuzz_splitDepositsReachUint256Maximum(uint256 firstSeed, bool sameRecipient) public {
        uint256 first = bound(firstSeed, 1, type(uint256).max - 1);
        uint256 second = type(uint256).max - first;
        address secondRecipient = sameRecipient ? alice : bob;
        token.mint(owner, type(uint256).max);
        _deposit(alice, first);
        _deposit(secondRecipient, second);
        assertEq(token.balanceOf(owner), 0);
        assertEq(escrow.totalClaimable(), type(uint256).max);
        assertEq(token.balanceOf(address(escrow)), type(uint256).max);
        assertEq(escrow.claimable(alice), sameRecipient ? type(uint256).max : first);
        assertEq(escrow.claimable(bob), sameRecipient ? 0 : second);

        vm.prank(alice);
        escrow.claim();
        if (!sameRecipient) {
            assertEq(escrow.totalClaimable(), second);
            assertEq(token.balanceOf(address(escrow)), second);
            vm.prank(bob);
            escrow.claim();
        }
        assertEq(token.balanceOf(alice), sameRecipient ? type(uint256).max : first);
        assertEq(token.balanceOf(bob), sameRecipient ? 0 : second);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);

        // Reuse the empty escrow without minting beyond the maximum supply.
        vm.prank(alice);
        token.transfer(owner, 1);
        _deposit(bob, 1);
        vm.prank(bob);
        escrow.claim();
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), type(uint256).max);
        assertEq(token.totalSupply(), type(uint256).max);
        assertEq(escrow.claimable(bob), 0);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_splitMaximumAtOneBaseUnitBoundaries() public {
        // Pin the smallest first deposit into a single recipient's balance.
        testFuzz_splitDepositsReachUint256Maximum(1, true);
    }

    function test_splitMaximumAcrossRecipientsAtLastBaseUnit() public {
        testFuzz_splitDepositsReachUint256Maximum(type(uint256).max - 1, false);
    }

    function testFuzz_failedTopUpWithSurplusPreservesAllStateAndCanRetry(
        uint128 creditSeed,
        uint128 topUpSeed,
        uint128 surplusSeed
    ) public {
        uint256 credit = uint256(creditSeed) + 1;
        uint256 topUp = uint256(topUpSeed) + 1;
        uint256 surplus = uint256(surplusSeed) + 1;
        token.mint(owner, credit + topUp + surplus);
        _deposit(alice, credit);
        vm.startPrank(owner);
        token.transfer(address(escrow), surplus);
        token.approve(address(escrow), topUp - 1);
        vm.expectRevert(MockUSDC.InsufficientAllowance.selector);
        escrow.deposit(alice, topUp);
        vm.stopPrank();
        assertEq(token.allowance(owner, address(escrow)), topUp - 1);
        assertEq(token.balanceOf(owner), topUp);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(escrow)), credit + surplus);
        assertEq(escrow.claimable(alice), credit);
        assertEq(escrow.totalClaimable(), credit);

        _deposit(alice, topUp);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), credit + topUp);
        assertEq(token.balanceOf(address(escrow)), surplus);
        assertEq(token.balanceOf(owner), 0);
        assertEq(escrow.totalClaimable(), 0);
        assertEq(token.totalSupply(), credit + topUp + surplus);
    }

    function test_newOwnerCannotUseFormerOwnersBalanceOrAllowance() public {
        token.mint(owner, 100e6);
        _deposit(alice, 25e6);
        vm.startPrank(owner);
        token.approve(address(escrow), 75e6);
        escrow.transferOwnership(bob);
        vm.stopPrank();
        vm.startPrank(bob);
        escrow.acceptOwnership();
        token.approve(address(escrow), 75e6);
        vm.expectRevert(MockUSDC.InsufficientBalance.selector);
        escrow.deposit(alice, 75e6);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), 75e6);
        assertEq(token.allowance(owner, address(escrow)), 75e6);
        assertEq(token.allowance(bob, address(escrow)), 75e6);
        assertEq(escrow.claimable(alice), 25e6);
        assertEq(escrow.totalClaimable(), 25e6);

        token.mint(bob, 5e6);
        vm.prank(bob);
        escrow.deposit(alice, 5e6);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(owner), 75e6);
        assertEq(token.allowance(owner, address(escrow)), 75e6);
        vm.prank(alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 30e6);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_relayCannotClaimOriginsCreditAndReceivesOnlyItsOwnAllocation() public {
        EscrowCallRelay relay = new EscrowCallRelay();
        token.mint(owner, 30e6);
        _deposit(alice, 20e6);
        vm.prank(alice, alice);
        vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        relay.claim(escrow);
        assertEq(escrow.claimable(alice), 20e6);

        _deposit(address(relay), 10e6);
        vm.prank(alice, alice);
        relay.claim(escrow);
        assertEq(token.balanceOf(address(relay)), 10e6);
        assertEq(token.balanceOf(alice), 0);
        assertEq(escrow.claimable(address(relay)), 0);
        assertEq(escrow.claimable(alice), 20e6);
        assertEq(escrow.totalClaimable(), 20e6);
        vm.prank(alice, alice);
        escrow.claim();
        assertEq(token.balanceOf(alice), 20e6);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_relayCannotUseOwnerOriginToDeposit() public {
        EscrowCallRelay relay = new EscrowCallRelay();
        token.mint(owner, 10e6);
        token.mint(address(relay), 10e6);
        vm.prank(owner);
        token.approve(address(escrow), 10e6);
        vm.prank(address(relay));
        token.approve(address(escrow), 10e6);
        vm.prank(owner, owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(relay)));
        relay.deposit(escrow, alice, 10e6);
        assertEq(token.balanceOf(owner), 10e6);
        assertEq(token.balanceOf(address(relay)), 10e6);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.allowance(owner, address(escrow)), 10e6);
        assertEq(token.allowance(address(relay), address(escrow)), 10e6);
        assertEq(escrow.claimable(alice), 0);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_reentrantDepositFailureRestoresPriorCreditAllowanceAndGuard() public {
        CallbackWallet wallet = new CallbackWallet();
        USDCDepositClaim target = new USDCDepositClaim(address(wallet));
        token.mint(address(wallet), 50e6);
        wallet.execute(address(token), abi.encodeCall(IERC20.approve, (address(target), 50e6)));
        wallet.execute(address(target), abi.encodeCall(target.deposit, (alice, 10e6)));
        wallet.configure(target, abi.encodeCall(target.deposit, (bob, 1)), true);
        token.setCallback(address(wallet), false, true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        wallet.execute(address(target), abi.encodeCall(target.deposit, (alice, 5e6)));
        assertEq(target.claimable(alice), 10e6);
        assertEq(target.claimable(bob), 0);
        assertEq(target.totalClaimable(), 10e6);
        assertEq(token.balanceOf(address(target)), 10e6);
        assertEq(token.balanceOf(address(wallet)), 40e6);
        assertEq(token.allowance(address(wallet), address(target)), 40e6);
        assertEq(wallet.callbackCount(), 0);

        token.setCallback(address(wallet), false, false);
        wallet.execute(address(target), abi.encodeCall(target.deposit, (alice, 5e6)));
        assertEq(target.claimable(alice), 15e6);
        assertEq(token.balanceOf(address(wallet)), 35e6);
        assertEq(token.allowance(address(wallet), address(target)), 35e6);
        vm.prank(alice);
        target.claim();
        assertEq(token.balanceOf(alice), 15e6);
        assertEq(target.totalClaimable(), 0);
    }

    function _deposit(address recipient, uint256 amount) private {
        vm.startPrank(owner);
        token.approve(address(escrow), amount);
        escrow.deposit(recipient, amount);
        vm.stopPrank();
    }
}
