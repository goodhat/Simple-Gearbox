// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ICreditManagerV2, ClosureAction} from "./interfaces/ICreditManagerV2.sol";
import {ICreditFacadeExceptions, ICreditFacadeEvents} from "./interfaces/ICreditFacade.sol";
import "./PriceOracle.sol";
import "./CreditManager.sol";

import {LEVERAGE_DECIMALS} from "./libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "./libraries/PercentageMath.sol";
import {MultiCall} from "./libraries/MultiCall.sol";

struct TotalDebt {
    /// @dev Current total borrowing
    uint128 currentTotalDebt;
    /// @dev Total borrowing limit
    uint128 totalDebtLimit; // Currently unused
}

contract CreditFacade is ICreditFacadeExceptions, ICreditFacadeEvents, ReentrancyGuard {
    using SafeCast for uint256;
    using Address for address;

    CreditManager public immutable creditManager;
    address public immutable underlying;
    address public immutable pool;
    TotalDebt public totalDebt;

    constructor(address _creditManager) {
        creditManager = CreditManager(_creditManager);
        underlying = CreditManager(_creditManager).underlying();
        pool = CreditManager(_creditManager).pool();

        totalDebt.totalDebtLimit = type(uint128).max;
    }

    function openCreditAccount(uint256 amount, address onBehalfOf, uint16 leverageFactor) external nonReentrant {
        uint256 borrowedAmount = (amount * leverageFactor) / LEVERAGE_DECIMALS;

        _checkAndUpdateTotalDebt(borrowedAmount, true);
        (, uint256 ltu) = creditManager.collateralTokens(0);
        if (amount * ltu <= borrowedAmount * (PERCENTAGE_FACTOR - ltu)) {
            revert NotEnoughCollateralException();
        }

        address creditAccount = creditManager.openCreditAccount(borrowedAmount, onBehalfOf);
        emit OpenCreditAccount(onBehalfOf, creditAccount, borrowedAmount, 0);
        addCollateral(onBehalfOf, creditAccount, underlying, amount);
    }

    function multicall(MultiCall[] calldata calls) external payable nonReentrant {
        // Checks that msg.sender has an account
        address creditAccount = creditManager.getCreditAccountOrRevert(msg.sender);

        if (calls.length != 0) {
            _multicall(calls, msg.sender);
            creditManager.fullCollateralCheck(creditAccount); // TODO
        }
    }

    // Simplified: remove isClosure and increaseDebtWasCalled flags
    function _multicall(MultiCall[] calldata calls, address borrower) internal {
        creditManager.transferAccountOwnership(borrower, address(this));
        emit MultiCallStarted(borrower);

        uint256 len = calls.length;
        for (uint256 i = 0; i < len; ++i) {
            MultiCall calldata mcall = calls[i];
            if (mcall.target == address(this)) {
                // Simplified: simply reject internal multi call
                revert("Not used yet");
            } else {
                if (
                    creditManager.adapterToContract(mcall.target) == address(0)
                        || mcall.target == address(creditManager)
                ) revert TargetContractNotAllowedException();

                mcall.target.functionCall(mcall.callData);
            }
        }

        // Simplified: does not check expected balances

        emit MultiCallFinished();
        creditManager.transferAccountOwnership(address(this), borrower);
    }

    function closeCreditAccount(address to, MultiCall[] calldata calls) external payable nonReentrant {
        _closeCreditAccount(to, calls);
    }

    function _closeCreditAccount(address to, MultiCall[] calldata calls) internal {
        address creditAccount = creditManager.getCreditAccountOrRevert(msg.sender);

        if (calls.length != 0) {
            _multicall(calls, msg.sender);
        }

        uint256 availableLiquidityBefore = _getAvailableLiquidity();
        (uint256 borrowedAmount, uint256 borrowAmountWithInterest) =
            creditManager.calcCreditAccountAccruedInterest(creditAccount);

        // TODO
        creditManager.closeCreditAccount(msg.sender, ClosureAction.CLOSE_ACCOUNT, 0, msg.sender, to);

        uint256 availableLiquidityAfter = _getAvailableLiquidity();
        if (availableLiquidityAfter < availableLiquidityBefore + borrowAmountWithInterest) {
            revert LiquiditySanityCheckException();
        }

        _checkAndUpdateTotalDebt(borrowedAmount, false);

        emit CloseCreditAccount(msg.sender, to);
    }

    function liquidateCreditAccount(address borrower, address to, MultiCall[] calldata calls)
        external
        payable
        nonReentrant
    {
        _liquidateCreditAccount(borrower, to, calls);
    }

    function _liquidateCreditAccount(address borrower, address to, MultiCall[] calldata calls) internal {
        address creditAccount = creditManager.getCreditAccountOrRevert(borrower);
        if (to == address(0)) revert ZeroAddressException();

        (bool isLiquidatable, uint256 totalValue) = _isAccountLiquidatable(creditAccount);
        if (!isLiquidatable) {
            revert CantLiquidateWithSuchHealthFactorException();
        }

        if (calls.length != 0) {
            _multicall(calls, borrower);
        }

        uint256 remainingFunds = _closeLiquidatedAccount(totalValue, creditAccount, borrower, to);
        emit LiquidateCreditAccount(borrower, msg.sender, to, remainingFunds);
    }

    function _closeLiquidatedAccount(uint256 totalValue, address creditAccount, address borrower, address to)
        internal
        returns (uint256 remainingFunds)
    {
        // Simplified: neglect blacklisted accounts

        uint256 availableLiquidityBefore = _getAvailableLiquidity();

        (uint256 borrowedAmount, uint256 borrowAmountWithInterest) =
            creditManager.calcCreditAccountAccruedInterest(creditAccount);

        remainingFunds =
            creditManager.closeCreditAccount(borrower, ClosureAction.LIQUIDATE_ACCOUNT, totalValue, msg.sender, to);

        uint256 availableLiquidityAfter = _getAvailableLiquidity();

        uint256 loss = availableLiquidityAfter < availableLiquidityBefore + borrowAmountWithInterest
            ? availableLiquidityBefore + borrowAmountWithInterest - availableLiquidityAfter
            : 0;

        if (loss > 0) {
            // Simplified: does not handle loss
            emit IncurLossOnLiquidation(loss);
        }

        // Decreases the total debt
        _checkAndUpdateTotalDebt(borrowedAmount, false);

        // Simplified: neglect blacklist
    }

    function _checkAndUpdateTotalDebt(uint256 delta, bool isIncrease) internal {
        if (delta > 0) {
            TotalDebt memory td = totalDebt;

            if (isIncrease) {
                td.currentTotalDebt += delta.toUint128();
                if (td.currentTotalDebt > td.totalDebtLimit) revert BorrowAmountOutOfLimitsException();
            } else {
                td.currentTotalDebt -= delta.toUint128();
            }
            totalDebt = td;
        }
    }

    function addCollateral(address onBehalfOf, address creditAccount, address token, uint256 amount) internal {
        // Simplified: only CreditAccount owner can add collateral
        if (msg.sender != onBehalfOf) revert AccountTransferNotAllowedException();

        // Requests Credit Manager to transfer collateral to the Credit Account
        creditManager.addCollateral(msg.sender, creditAccount, token, amount);

        // Emits event
        emit AddCollateral(onBehalfOf, token, amount);
    }

    function calcCreditAccountHealthFactor(address creditAccount) public view returns (uint256 hf) {
        SimplePriceOracle priceOracle = SimplePriceOracle(creditManager.priceOracle());
        (, uint256 borrowAmountWithInterest) = creditManager.calcCreditAccountAccruedInterest(creditAccount);
        uint256 borrowAmountWithInterestUSD = priceOracle.convertToUSD(borrowAmountWithInterest, underlying);

        // TODO: Use _calcTotalValueUSD
        uint256 twvUSD;
        uint256 tokenMask = 1;
        uint256 enabledTokensMask = creditManager.enabledTokensMap(creditAccount);
        while (tokenMask <= enabledTokensMask) {
            if (enabledTokensMask & tokenMask != 0) {
                (address token, uint16 liquidationThreshold) = creditManager.collateralTokensByMask(tokenMask);
                uint256 balance = IERC20(token).balanceOf(creditAccount);

                if (balance > 1) {
                    uint256 value = priceOracle.convertToUSD(balance, token);
                    twvUSD += value * liquidationThreshold;
                }
            }
            tokenMask = tokenMask << 1;
        }
        twvUSD = twvUSD / PERCENTAGE_FACTOR;
        hf = (twvUSD * PERCENTAGE_FACTOR) / borrowAmountWithInterestUSD;
    }

    function _calcTotalValueUSD(SimplePriceOracle priceOracle, address creditAccount)
        internal
        view
        returns (uint256 totalUSD, uint256 twvUSD)
    {
        uint256 tokenMask = 1;
        uint256 enabledTokensMask = creditManager.enabledTokensMap(creditAccount);

        while (tokenMask <= enabledTokensMask) {
            if (enabledTokensMask & tokenMask != 0) {
                (address token, uint16 liquidationThreshold) = creditManager.collateralTokensByMask(tokenMask);
                uint256 balance = IERC20(token).balanceOf(creditAccount);

                if (balance > 1) {
                    uint256 value = priceOracle.convertToUSD(balance, token);

                    unchecked {
                        totalUSD += value;
                    }
                    twvUSD += value * liquidationThreshold;
                }
            }

            tokenMask = tokenMask << 1;
        }
    }

    function _isAccountLiquidatable(address creditAccount)
        internal
        view
        returns (bool isLiquidatable, uint256 totalValue)
    {
        SimplePriceOracle priceOracle = SimplePriceOracle(creditManager.priceOracle());

        (uint256 totalUSD, uint256 twvUSD) = _calcTotalValueUSD(priceOracle, creditAccount);

        // Computes total value in underlying
        totalValue = priceOracle.convertFromUSD(totalUSD, underlying);

        (, uint256 borrowAmountWithInterest) = creditManager.calcCreditAccountAccruedInterest(creditAccount); // F:[FA-14]

        // borrowAmountPlusInterestRateUSD x 10000 to be compared with USD values multiplied by LTs
        uint256 borrowAmountPlusInterestRateUSD =
            priceOracle.convertToUSD(borrowAmountWithInterest, underlying) * PERCENTAGE_FACTOR;

        // Checks that current Hf < 1
        isLiquidatable = twvUSD < borrowAmountPlusInterestRateUSD;
    }

    function _getAvailableLiquidity() internal view returns (uint256) {
        return IERC20(underlying).balanceOf(pool);
    }
}
