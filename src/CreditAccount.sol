// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICreditAccount.sol";

/// @title Credit Account
/// @notice Implements generic credit account logic:
///   - Holds collateral assets
///   - Stores general parameters: borrowed amount, cumulative index at open and block when it was initialized
///   - Transfers assets
///   - Executes financial orders by calling connected protocols on its behalf
///
///  More: https://dev.gearbox.fi/developers/credit/credit_account
contract CreditAccount is ICrediAccountExceptions {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @dev Address of the currently connected Credit Manager
    address public creditManager;

    /// @dev The principal amount borrowed from the pool
    uint256 public borrowedAmount;

    /// @dev Cumulative interest index since the last Credit Account's debt update
    uint256 public cumulativeIndexAtOpen;

    /// @dev Block at which the contract was last taken from the factory
    uint256 public since;

    /// @dev Restricts operations to the connected Credit Manager only
    modifier creditManagerOnly() {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
        _;
    }

    constructor(uint256 _borrowedAmount, uint256 _cumulativeIndexAtOpen) {
        borrowedAmount = _borrowedAmount;
        cumulativeIndexAtOpen = _cumulativeIndexAtOpen;
        since = block.number;
        creditManager = msg.sender;
    }

    /// @dev Updates borrowed amount and cumulative index. Restricted to the currently connected Credit Manager.
    /// @param _borrowedAmount The amount currently lent to the Credit Account
    /// @param _cumulativeIndexAtOpen New cumulative index to calculate interest from
    function updateParameters(uint256 _borrowedAmount, uint256 _cumulativeIndexAtOpen) external creditManagerOnly {
        borrowedAmount = _borrowedAmount;
        cumulativeIndexAtOpen = _cumulativeIndexAtOpen;
    }

    /// @dev Removes allowance for a token to a 3rd-party contract. Restricted to factory only.
    /// @param token ERC20 token to remove allowance for.
    /// @param targetContract Target contract to revoke allowance to.
    function cancelAllowance(address token, address targetContract) external creditManagerOnly {
        IERC20(token).safeApprove(targetContract, 0);
    }

    /// @dev Transfers tokens from the credit account to a provided address. Restricted to the current Credit Manager only.
    /// @param token Token to be transferred from the Credit Account.
    /// @param to Address of the recipient.
    /// @param amount Amount to be transferred.
    function safeTransfer(address token, address to, uint256 amount)
        external
        creditManagerOnly // T:[CA-2]
    {
        IERC20(token).safeTransfer(to, amount); // T:[CA-6]
    }

    /// @dev Executes a call to a 3rd party contract with provided data. Restricted to the current Credit Manager only.
    /// @param destination Contract address to be called.
    /// @param data Data to call the contract with.
    function execute(address destination, bytes memory data) external creditManagerOnly returns (bytes memory) {
        return destination.functionCall(data); // T: [CM-48]
    }
}
