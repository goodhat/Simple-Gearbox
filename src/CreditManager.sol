// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

// LIBRARIES
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/ICreditManagerV2.sol";
import "./interfaces/ICreditAccount.sol";
import "./interfaces/IPoolService.sol";
import "./interfaces/IPriceOracle.sol";
import "./CreditAccount.sol";
import "./PriceOracle.sol";

import "./libraries/Constants.sol";

contract CreditManager is ICreditManagerV2Exceptions, ICreditManagerV2Events {
    using SafeERC20 for IERC20;
    using Address for address payable;
    using SafeCast for uint256;

    bool private entered;

    // Simplified: Most fields in Slot 1 are unused
    SimplePriceOracle public priceOracle;
    uint16 public ltUnderlying;
    uint16 public liquidationDiscount;

    address public creditFacade;
    address public owner;
    mapping(address => address) public creditAccounts;
    address public immutable underlying;
    address public immutable poolService;
    address public immutable pool;

    uint256 public collateralTokensCount;

    mapping(address => uint256) internal tokenMasksMapInternal;
    mapping(uint256 => uint256) internal collateralTokensCompressed;
    mapping(address => uint256) public enabledTokensMap;
    mapping(address => address) public adapterToContract;
    mapping(address => address) public contractToAdapter;

    modifier nonReentrant() {
        if (entered) {
            revert ReentrancyLockException();
        }

        entered = true;
        _;
        entered = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert OnlyOwnerException();
        }
        _;
    }

    modifier creditFacadeOnly() {
        if (msg.sender != creditFacade) revert CreditFacadeOnlyException();
        _;
    }

    modifier adaptersOrCreditFacadeOnly() {
        if (adapterToContract[msg.sender] == address(0) && msg.sender != creditFacade) {
            revert AdaptersOrCreditFacadeOnlyException();
        }
        _;
    }

    constructor(address _pool, address _underlying) {
        poolService = _pool;
        pool = _pool;
        underlying = _underlying;
        _addToken(underlying);
        owner = msg.sender;
    }

    function upgradeCreditFacade(address _creditFacade) external onlyOwner {
        creditFacade = _creditFacade;
    }

    function setPriceOracle(address _priceOracle) external onlyOwner {
        priceOracle = SimplePriceOracle(_priceOracle);
    }

    function setLiquidationDiscount(uint16 _liquidationDiscount) external onlyOwner {
        liquidationDiscount = _liquidationDiscount;
    }

    function openCreditAccount(uint256 borrowedAmount, address who)
        external
        nonReentrant
        creditFacadeOnly
        returns (address)
    {
        // Simplified: no factory, and no proxy
        address creditAccount =
            address(new CreditAccount(borrowedAmount, IPoolService(pool).calcLinearCumulative_RAY())); // TODO input interest
        IPoolService(poolService).lendCreditAccount(borrowedAmount, creditAccount);
        _safeCreditAccountSet(who, creditAccount);
        enabledTokensMap[creditAccount] = 1;
        return creditAccount;
    }

    /// @dev Transfers Credit Account ownership to another address
    /// @param from Address of previous owner
    /// @param to Address of new owner
    function transferAccountOwnership(address from, address to) external nonReentrant creditFacadeOnly {
        address creditAccount = getCreditAccountOrRevert(from);
        delete creditAccounts[from];

        _safeCreditAccountSet(to, creditAccount);
    }

    /// @dev Returns the collateral token at requested index and its liquidation threshold
    /// @param id The index of token to return
    function collateralTokens(uint256 id) public view returns (address token, uint16 liquidationThreshold) {
        // Collateral tokens are stored under their masks rather than
        // indicies, so this is simply a convenience function that wraps
        // the getter by mask
        return collateralTokensByMask(1 << id);
    }

    /// @dev Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function collateralTokensByMask(uint256 tokenMask)
        public
        view
        returns (address token, uint16 liquidationThreshold)
    {
        // The underlying is a special case and its mask is always 1
        if (tokenMask == 1) {
            token = underlying;
            liquidationThreshold = ltUnderlying;
        } else {
            uint256 collateralTokenCompressed = collateralTokensCompressed[tokenMask];
            token = address(uint160(collateralTokenCompressed));
            liquidationThreshold = (collateralTokenCompressed >> ADDR_BIT_SIZE).toUint16();
        }
    }

    function tokenMasksMap(address token) public view returns (uint256 mask) {
        mask = (token == underlying) ? 1 : tokenMasksMapInternal[token];
    }

    function setLiquidationThreshold(address token, uint16 liquidationThreshold) external onlyOwner {
        if (token == underlying) {
            ltUnderlying = liquidationThreshold;
        } else {
            uint256 tokenMask = tokenMasksMap(token);
            if (tokenMask == 0) revert TokenNotAllowedException();
            collateralTokensCompressed[tokenMask] =
                (collateralTokensCompressed[tokenMask] & type(uint160).max) | (uint256(liquidationThreshold) << 160);
        }
    }

    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        nonReentrant
        creditFacadeOnly
    {
        _checkAndEnableToken(creditAccount, token);
        IERC20(token).safeTransferFrom(payer, creditAccount, amount);
    }

    function changeContractAllowance(address adapter, address targetContract) external onlyOwner {
        if (adapter != address(0)) {
            adapterToContract[adapter] = targetContract;
        }
        if (targetContract != address(0)) {
            contractToAdapter[targetContract] = adapter;
        }

        // Simplified: neglet universal adapter
    }

    function approveCreditAccount(address borrower, address targetContract, address token, uint256 amount)
        external
        nonReentrant
    {
        if (
            (adapterToContract[msg.sender] != targetContract && msg.sender != creditFacade)
                || targetContract == address(0)
        ) {
            revert AdaptersOrCreditFacadeOnlyException();
        }

        if (tokenMasksMap(token) == 0) revert TokenNotAllowedException();

        address creditAccount = getCreditAccountOrRevert(borrower);

        // Simplified: Don't handle different approve implementaiton
        _approve(token, targetContract, creditAccount, amount);
    }

    function _approve(address token, address targetContract, address creditAccount, uint256 amount) internal {
        try ICreditAccount(creditAccount).execute(token, abi.encodeCall(IERC20.approve, (targetContract, amount)))
        returns (bytes memory result) {
            if (result.length == 0 || abi.decode(result, (bool)) == true) {
                return;
            }
        } catch {}

        // Simplified: always revert if approve fail
        revert AllowanceFailedException();
    }

    function executeOrder(address borrower, address targetContract, bytes memory data)
        external
        nonReentrant
        returns (bytes memory)
    {
        if (adapterToContract[msg.sender] != targetContract || targetContract == address(0)) {
            revert TargetContractNotAllowedException();
        }

        address creditAccount = getCreditAccountOrRevert(borrower);
        emit ExecuteOrder(borrower, targetContract);
        return ICreditAccount(creditAccount).execute(targetContract, data);
    }

    function _safeCreditAccountSet(address borrower, address creditAccount) internal {
        if (borrower == address(0) || creditAccounts[borrower] != address(0)) {
            revert ZeroAddressOrUserAlreadyHasAccountException();
        }
        creditAccounts[borrower] = creditAccount;
    }

    function addToken(address token) external onlyOwner {
        _addToken(token);
    }

    function _addToken(address token) internal {
        if (tokenMasksMapInternal[token] > 0) {
            revert TokenAlreadyAddedException();
        }

        if (collateralTokensCount >= 256) revert TooManyTokensException();

        uint256 tokenMask = 1 << collateralTokensCount;
        tokenMasksMapInternal[token] = tokenMask;
        collateralTokensCompressed[tokenMask] = uint256(uint160(token));
        collateralTokensCount++;
    }

    function checkAndEnableToken(address creditAccount, address token)
        external
        adaptersOrCreditFacadeOnly
        nonReentrant
    {
        _checkAndEnableToken(creditAccount, token);
    }

    function _checkAndEnableToken(address creditAccount, address token) internal {
        uint256 tokenMask = tokenMasksMap(token);

        // Simplified: No forbidden token mask
        if (tokenMask == 0) {
            revert TokenNotAllowedException();
        }

        if (enabledTokensMap[creditAccount] & tokenMask == 0) {
            enabledTokensMap[creditAccount] |= tokenMask;
        }
    }

    function closeCreditAccount(
        address borrower,
        ClosureAction closureActionType,
        uint256 totalValue,
        address payer,
        address to
    ) external nonReentrant creditFacadeOnly returns (uint256 remainingFunds) {
        // Simplified: only close and liquidate closure action type

        address creditAccount = getCreditAccountOrRevert(borrower);
        delete creditAccounts[borrower];

        uint256 amountToPool;
        uint256 borrowedAmount;

        {
            uint256 profit;
            uint256 loss;
            uint256 borrowedAmountWithInterest;
            (borrowedAmount, borrowedAmountWithInterest) = calcCreditAccountAccruedInterest(creditAccount);

            (amountToPool, remainingFunds, profit, loss) =
                calcClosePayments(totalValue, closureActionType, borrowedAmount, borrowedAmountWithInterest);

            uint256 underlyingBalance = IERC20(underlying).balanceOf(creditAccount);

            console.log(totalValue, underlyingBalance, amountToPool, remainingFunds);
            if (underlyingBalance > amountToPool + remainingFunds + 1) {
                unchecked {
                    console.log("repay to: %d", underlyingBalance - amountToPool - remainingFunds - 1);
                    _safeTokenTransfer(
                        creditAccount, underlying, to, underlyingBalance - amountToPool - remainingFunds - 1
                    );
                }
            } else {
                unchecked {
                    IERC20(underlying).safeTransferFrom(
                        payer, creditAccount, amountToPool + remainingFunds - underlyingBalance + 1
                    );
                }
            }
            console.log("repay pool: %d", amountToPool);
            _safeTokenTransfer(creditAccount, underlying, pool, amountToPool);
            IPoolService(pool).repayCreditAccount(borrowedAmount, profit, loss);
        }

        if (remainingFunds > 1) {
            console.log("repay borrower: %d", remainingFunds);
            _safeTokenTransfer(creditAccount, underlying, borrower, remainingFunds);
        }

        // Simplified: neglect skipTokenMask
        _transferAssetsTo(creditAccount, to, enabledTokensMap[creditAccount]);
    }

    function fullCollateralCheck(address creditAccount) external adaptersOrCreditFacadeOnly nonReentrant {
        _fullCollateralCheck(creditAccount);
    }

    function _fullCollateralCheck(address creditAccount) internal {
        uint256 enabledTokenMask = enabledTokensMap[creditAccount];
        (, uint256 borrowedAmountWithInterest) = calcCreditAccountAccruedInterest(creditAccount);

        uint256 borrowedAmountWithInterestUSD =
            priceOracle.convertToUSD(borrowedAmountWithInterest, underlying) * PERCENTAGE_FACTOR;

        // Simplified: remove several gas optimized condition checks
        // Simplified: does not restrict the number of enabled tokens
        uint256 tokenMask;
        uint256 twvUSD;
        for (uint256 i; i < 256; ++i) {
            tokenMask = 1 << i;
            if (enabledTokenMask & tokenMask != 0) {
                (address token, uint16 liquidationThreshold) = collateralTokensByMask(tokenMask);
                uint256 balance = IERC20(token).balanceOf(creditAccount);
                twvUSD += priceOracle.convertToUSD(balance, token) * liquidationThreshold;
                if (twvUSD >= borrowedAmountWithInterestUSD) {
                    return;
                }
            }
        }

        revert NotEnoughCollateralException();
    }

    function calcCreditAccountAccruedInterest(address creditAccount)
        public
        view
        returns (uint256 borrowedAmount, uint256 borrowedAmountWithInterest)
    {
        uint256 cumulativeIndexAtOpen_RAY;
        uint256 cumulativeIndexNow_RAY;
        (borrowedAmount, cumulativeIndexAtOpen_RAY, cumulativeIndexNow_RAY) = _getCreditAccountParameters(creditAccount);
        borrowedAmountWithInterest = (borrowedAmount * cumulativeIndexNow_RAY) / cumulativeIndexAtOpen_RAY;

        // Simplified: neglect protocol fee
    }

    function _getCreditAccountParameters(address creditAccount)
        internal
        view
        returns (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen_RAY, uint256 cumulativeIndexNow_RAY)
    {
        borrowedAmount = ICreditAccount(creditAccount).borrowedAmount();
        cumulativeIndexAtOpen_RAY = ICreditAccount(creditAccount).cumulativeIndexAtOpen();
        cumulativeIndexNow_RAY = IPoolService(pool).calcLinearCumulative_RAY();
    }

    function getCreditAccountOrRevert(address borrower) public view returns (address result) {
        result = creditAccounts[borrower];
        if (result == address(0)) revert HasNoOpenedAccountException();
    }

    function _safeTokenTransfer(address creditAccount, address token, address to, uint256 amount) internal {
        // Simplified: does not handle weth
        ICreditAccount(creditAccount).safeTransfer(token, to, amount);
    }

    function calcClosePayments(
        uint256 totalValue,
        ClosureAction closureActionType,
        uint256,
        uint256 borrowedAmountWithInterest
    ) public view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        // Simplified: no liquidation discount, no liquidation fee
        amountToPool = borrowedAmountWithInterest;
        if (closureActionType == ClosureAction.LIQUIDATE_ACCOUNT) {
            uint256 totalFunds = totalValue * liquidationDiscount / PERCENTAGE_FACTOR;
            unchecked {
                if (totalFunds > amountToPool) {
                    remainingFunds = totalFunds - amountToPool - 1;
                } else {
                    amountToPool = totalFunds;
                }
            }
        }
    }

    function _transferAssetsTo(address creditAccount, address to, uint256 enabledTokensMask) internal {
        uint256 tokenMask = 2;

        while (tokenMask <= enabledTokensMask) {
            if (enabledTokensMask & tokenMask != 0) {
                (address token,) = collateralTokensByMask(tokenMask);
                uint256 amount = IERC20(token).balanceOf(creditAccount);
                if (amount > 1) {
                    unchecked {
                        _safeTokenTransfer(creditAccount, token, to, amount - 1);
                    }
                }
            }

            tokenMask = tokenMask << 1;
        }
    }
}
