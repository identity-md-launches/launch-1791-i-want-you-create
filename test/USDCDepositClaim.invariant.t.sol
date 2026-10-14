// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {USDCDepositClaim} from "../src/USDCDepositClaim.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @dev Ghost accounting is updated from successful actions, independently of escrow storage.
contract DepositClaimHandler is Test {
    MockUSDC public immutable token;
    USDCDepositClaim public immutable escrow;
    address[4] public recipients;
    mapping(address => uint256) public expectedClaimable;
    mapping(address => uint256) public paid;
    uint256 public deposited;
    uint256 public claimed;
    uint256 public donated;

    constructor(MockUSDC token_) {
        token = token_;
        escrow = new USDCDepositClaim(address(this));
        for (uint256 i; i < recipients.length; ++i) {
            recipients[i] = makeAddr(string.concat("invariant recipient ", vm.toString(i)));
        }
    }

    function deposit(uint256 recipientSeed, uint256 amountSeed) public {
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        token.mint(address(this), amount);
        token.approve(address(escrow), amount);
        escrow.deposit(recipient, amount);
        expectedClaimable[recipient] += amount;
        deposited += amount;
    }

    function claim(uint256 recipientSeed) public {
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 amount = expectedClaimable[recipient];
        vm.prank(recipient);
        if (amount == 0) vm.expectRevert(USDCDepositClaim.NothingToClaim.selector);
        escrow.claim();
        expectedClaimable[recipient] = 0;
        paid[recipient] += amount;
        claimed += amount;
    }

    function donate(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        token.mint(address(this), amount);
        token.transfer(address(escrow), amount);
        donated += amount;
    }

    function unauthorizedDeposit(uint256 recipientSeed, uint256 amountSeed) public {
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, recipient));
        escrow.deposit(recipient, amount);
    }

    function blockedClaim(uint256 recipientSeed) public {
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 amount = expectedClaimable[recipient];
        token.setBlacklisted(recipient, true);
        vm.prank(recipient);
        vm.expectRevert(
            amount == 0 ? USDCDepositClaim.NothingToClaim.selector : MockUSDC.Blacklisted.selector
        );
        escrow.claim();
        assertEq(escrow.claimable(recipient), amount);
        token.setBlacklisted(recipient, false);
    }

    function failedDeposit(uint256 recipientSeed, uint256 amountSeed) public {
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        token.mint(address(this), amount);
        token.approve(address(escrow), amount);
        token.setBehavior(MockUSDC.Behavior.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        escrow.deposit(recipient, amount);
        token.setBehavior(MockUSDC.Behavior.Normal);
    }
}

contract USDCDepositClaimInvariantTest is StdInvariant, Test {
    MockUSDC private token;
    USDCDepositClaim private escrow;
    DepositClaimHandler private handler;

    function setUp() public {
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        vm.etch(usdc, address(new MockUSDC()).code);
        token = MockUSDC(usdc);
        handler = new DepositClaimHandler(token);
        escrow = handler.escrow();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.unauthorizedDeposit.selector;
        selectors[4] = handler.blockedClaim.selector;
        selectors[5] = handler.failedDeposit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_creditsEqualFundedUnclaimedAmounts() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address recipient = handler.recipients(i);
            uint256 expected = handler.expectedClaimable(recipient);
            assertEq(escrow.claimable(recipient), expected);
            sum += expected;
        }
        assertEq(escrow.totalClaimable(), sum);
        assertEq(handler.deposited(), handler.claimed() + sum);
    }

    function invariant_escrowAlwaysBacksAllCreditsAndKeepsDonationsSeparate() public view {
        assertEq(token.balanceOf(address(escrow)), escrow.totalClaimable() + handler.donated());
    }

    function invariant_onlyRecipientsReceiveTheirClaims() public view {
        for (uint256 i; i < 4; ++i) {
            address recipient = handler.recipients(i);
            assertEq(token.balanceOf(recipient), handler.paid(recipient));
        }
    }

    function afterInvariant() public {
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        assertEq(escrow.totalClaimable(), 0);
        assertEq(handler.deposited(), handler.claimed());
        assertEq(token.balanceOf(address(escrow)), handler.donated());
    }
}
