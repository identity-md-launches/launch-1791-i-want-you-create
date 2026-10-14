// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title USDCDepositClaim
/// @notice The owner funds balances that only their designated recipients may claim.
/// @dev Ethereum mainnet USDC only. All amounts are integer USDC base units (six decimals).
contract USDCDepositClaim is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    mapping(address recipient => uint256 amount) public claimable;
    uint256 public totalClaimable;

    error InvalidRecipient(address recipient);
    error ZeroAmount();
    error NothingToClaim();
    error TokenUnavailable();
    error UnexpectedTokenBalance();
    error OwnershipRenunciationDisabled();

    event Deposited(address indexed funder, address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);

    /// @param initialOwner The launch owner's wallet, never the deploying factory.
    /// @dev Does not call USDC or require external contracts to exist during deployment.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Pull `amount` USDC from the owner and add it to `recipient`'s claimable balance.
    /// @dev The owner must first approve this contract on USDC. Requires exact funding;
    ///      pre-existing donations cannot substitute for a transfer from the owner.
    function deposit(address recipient, uint256 amount) external nonReentrant onlyOwner {
        if (recipient == address(0) || recipient == address(this) || recipient == address(USDC)) {
            revert InvalidRecipient(recipient);
        }
        if (amount == 0) revert ZeroAmount();
        _requireToken();

        uint256 balanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = USDC.balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert UnexpectedTokenBalance();
        }

        claimable[recipient] += amount;
        totalClaimable += amount;
        emit Deposited(msg.sender, recipient, amount);
    }

    /// @notice Claim your entire credited balance to your own wallet.
    /// @dev Clears accounting before the transfer; a failed transfer restores all state.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _requireToken();

        uint256 escrowBefore = USDC.balanceOf(address(this));
        uint256 recipientBefore = USDC.balanceOf(msg.sender);
        claimable[msg.sender] = 0;
        totalClaimable -= amount;

        USDC.safeTransfer(msg.sender, amount);
        uint256 escrowAfter = USDC.balanceOf(address(this));
        uint256 recipientAfter = USDC.balanceOf(msg.sender);
        if (
            escrowAfter > escrowBefore || escrowBefore - escrowAfter != amount
                || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
        ) revert UnexpectedTokenBalance();

        emit Claimed(msg.sender, amount);
    }

    /// @notice Ownership may be transferred with two-step acceptance, but cannot be renounced.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function _requireToken() private view {
        if (address(USDC).code.length == 0) revert TokenUnavailable();
    }
}
