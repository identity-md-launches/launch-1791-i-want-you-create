// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only token installed at the fixed USDC address with vm.etch.
///      No constructor state is required. This is not a production token.
contract MockUSDC is IERC20 {
    enum Behavior {
        Normal,
        ReturnFalse,
        NoReturn,
        RevertTransfer,
        ShortTransfer,
        NoTransfer,
        ExtraCredit,
        InvalidReturn
    }

    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;
    bool public paused;
    Behavior public behavior;
    address public callback;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;

    error InsufficientBalance();
    error InsufficientAllowance();
    error TokenPaused();
    error Blacklisted();
    error TransferReverted();

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
        totalSupply += amount;
        emit Transfer(address(0), recipient, amount);
    }

    function setBehavior(Behavior value) external {
        behavior = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function setCallback(address target, bool onTransfer, bool onTransferFrom) external {
        callback = target;
        callbackOnTransfer = onTransfer;
        callbackOnTransferFrom = onTransferFrom;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        if (callbackOnTransfer) _callback();
        return _returnValue();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = approved - amount;
        _move(from, to, amount);
        if (callbackOnTransferFrom) _callback();
        return _returnValue();
    }

    function _move(address from, address to, uint256 amount) private {
        if (paused) revert TokenPaused();
        if (blacklisted[from] || blacklisted[to] || blacklisted[msg.sender]) revert Blacklisted();
        if (behavior == Behavior.RevertTransfer) revert TransferReverted();
        if (behavior == Behavior.NoTransfer) return;
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        uint256 received = amount;
        if (behavior == Behavior.ShortTransfer && amount > 0) {
            received -= 1;
            totalSupply -= 1;
        } else if (behavior == Behavior.ExtraCredit) {
            received += 1;
            totalSupply += 1;
        }
        balanceOf[to] += received;
        emit Transfer(from, to, received);
    }

    function _returnValue() private view returns (bool) {
        if (behavior == Behavior.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (behavior == Behavior.InvalidReturn) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return behavior != Behavior.ReturnFalse;
    }

    function _callback() private {
        (bool success, bytes memory result) = callback.call(abi.encodeWithSignature("onTokenCallback()"));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
