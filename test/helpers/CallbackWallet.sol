// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {USDCDepositClaim} from "../../src/USDCDepositClaim.sol";

/// @dev Test-only contract wallet that attempts to reenter when the mock token calls it.
contract CallbackWallet {
    address public immutable controller = msg.sender;
    USDCDepositClaim public escrow;
    bytes private attack;
    bool private bubbleFailure;
    bool public attackSucceeded;
    bytes public attackResult;
    uint256 public observedClaimable;
    uint256 public observedTotal;
    uint256 public callbackCount;

    function configure(USDCDepositClaim target, bytes calldata data, bool bubble) external {
        require(msg.sender == controller, "controller only");
        escrow = target;
        attack = data;
        bubbleFailure = bubble;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == controller, "controller only");
        bool success;
        (success, result) = target.call(data);
        if (!success) _revert(result);
    }

    function onTokenCallback() external {
        require(msg.sender == address(escrow.USDC()), "token only");
        callbackCount++;
        observedClaimable = escrow.claimable(address(this));
        observedTotal = escrow.totalClaimable();
        (attackSucceeded, attackResult) = address(escrow).call(attack);
        if (!attackSucceeded && bubbleFailure) _revert(attackResult);
    }

    function _revert(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }
}
