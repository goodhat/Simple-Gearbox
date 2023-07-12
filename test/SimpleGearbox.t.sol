// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/CreditAccount.sol";
import "../src/CreditManager.sol";
import "../src/CreditFacade.sol";
import "../src/PoolService.sol";
import "../src/LinearInterestRateModel.sol";
import "../src/PriceOracle.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/libraries/Constants.sol";
import {MultiCall} from "../src/libraries/MultiCall.sol";

import "./helpers/UsefulAddresses.sol";

contract SimpleGearboxTest is Test, UsefulAddresses {
    string _MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    uint256 constant POOL_INITAIL_LIQUIDITY = 1e20;
    address admin = makeAddr("admin");
    address lpProvider = makeAddr("lpProvider");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    CreditManager public creditManager;
    CreditFacade public creditFacade;
    LinearInterestRateModel public interestRateModel;
    PoolService public poolService;
    UniswapV2Adapter public uniswapV2Adapter;
    SimplePriceOracle priceOracle;

    function setUp() public {
        super.labelAddress();
        vm.createSelectFork(_MAINNET_RPC_URL);
        vm.rollFork(17600000);
        vm.startPrank(admin);

        // Create USDC pool, interest rate model, oracle
        interestRateModel = new LinearInterestRateModel(0, 0, 0, 0); // Simplified: neglect interest
        poolService = new PoolService(address(USDC), address(interestRateModel), type(uint256).max);
        priceOracle = new SimplePriceOracle();

        // Create CreditManager
        creditManager = new CreditManager(address(poolService), address(USDC));
        creditManager.setPriceOracle(address(priceOracle));
        poolService.connectCreditManager(address(creditManager));

        // Create CreditFacade
        creditFacade = new CreditFacade(address(creditManager));
        creditManager.upgradeCreditFacade(address(creditFacade));

        // Create adapter and set allowance
        uniswapV2Adapter = new UniswapV2Adapter(address(creditManager), address(UNISWAP_V2_ROUTER));
        creditManager.changeContractAllowance(address(uniswapV2Adapter), address(UNISWAP_V2_ROUTER));

        // Set token lt and ld
        creditManager.setLiquidationThreshold(address(USDC), 1e4); // 100%
        creditManager.addToken(address(WETH));
        creditManager.setLiquidationThreshold(address(WETH), 9e3); // 90%
        creditManager.setLiquidationDiscount(8e3); // 20% off discount

        // Set initial price
        priceOracle.setToUSD(address(USDC), 1e8); // price decimal = 8
        priceOracle.setToUSD(address(WETH), 1800e8);

        // Add liquidity to pool
        changePrank(lpProvider);
        deal(address(USDC), lpProvider, POOL_INITAIL_LIQUIDITY, true);
        USDC.approve(address(poolService), POOL_INITAIL_LIQUIDITY);
        poolService.addLiquidity(POOL_INITAIL_LIQUIDITY, lpProvider, 0);

        vm.stopPrank();

        vm.label(admin, "admin");
        vm.label(lpProvider, "lpProvider");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(address(creditManager), "creditManager");
        vm.label(address(creditFacade), "creditFacade");
        vm.label(address(interestRateModel), "interestRateModel");
        vm.label(address(poolService), "poolService");
        vm.label(address(uniswapV2Adapter), "uniswapV2Adapter");
        vm.label(address(priceOracle), "priceOracle");
    }

    function testOpenCreditAccountAndCloseAcount() public {
        uint256 AMOUNT_OPEN_WITH = 1000e6; // 1000 USDC
        uint16 LEVERAGE_RATIO = 500; // 6x leverage

        // Open credit account
        vm.startPrank(user1);
        deal(address(USDC), user1, AMOUNT_OPEN_WITH, true);
        USDC.approve(address(creditManager), AMOUNT_OPEN_WITH);
        creditFacade.openCreditAccount(AMOUNT_OPEN_WITH, user1, LEVERAGE_RATIO);

        // Check borrowed amount
        address creditAccount = creditManager.getCreditAccountOrRevert(user1);
        assertEq(USDC.balanceOf(creditAccount), AMOUNT_OPEN_WITH * (1 + LEVERAGE_RATIO / LEVERAGE_DECIMALS));

        // Swap 5000 USDC for WETH via UniswapV2Router
        MultiCall[] memory mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapExactTokensForTokens, (AMOUNT_OPEN_WITH * 5, 0, path, address(0), block.timestamp)
        );
        creditFacade.multicall(mcalls);

        // Assume user1 earn the exact usdc as debt and decide to close the account
        // When closing the account, all USDC will be repayed to pool, and WETH will
        // be transfered to user1.
        deal(address(USDC), creditAccount, 5000000001);
        MultiCall[] memory closeMcalls;
        creditFacade.closeCreditAccount(user1, closeMcalls);
    }

    function testOpenCreditAccountAndLiquidate() public {
        uint256 AMOUNT_OPEN_WITH = 1000e6; // 1000 USDC
        uint16 LEVERAGE_RATIO = 500; // 6x leverage

        vm.startPrank(user1);
        deal(address(USDC), user1, AMOUNT_OPEN_WITH, true);
        USDC.approve(address(creditManager), AMOUNT_OPEN_WITH);
        creditFacade.openCreditAccount(AMOUNT_OPEN_WITH, user1, LEVERAGE_RATIO);

        address creditAccount = creditManager.getCreditAccountOrRevert(user1);
        assertEq(USDC.balanceOf(creditAccount), AMOUNT_OPEN_WITH * (1 + LEVERAGE_RATIO / LEVERAGE_DECIMALS));

        MultiCall[] memory mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapExactTokensForTokens, (AMOUNT_OPEN_WITH * 5, 0, path, address(0), block.timestamp)
        );
        creditFacade.multicall(mcalls);

        // Lower WETH price. This will turn the credit account into unhealthy,
        // so we can test liquidation.
        assert(creditFacade.calcCreditAccountHealthFactor(creditAccount) > 1e4);
        changePrank(admin);
        priceOracle.setToUSD(address(WETH), 1600 * 1e8);
        assert(creditFacade.calcCreditAccountHealthFactor(creditAccount) < 1e4);

        // User2 liquidate user1's credit account
        changePrank(user2);

        // // Liquidation method 1:
        // //   Pay debt and remaining fund by user2 itself.
        // //   Get remaining USDC and WETH.
        // deal(address(USDC), user2, 100000e6);
        // USDC.approve(address(creditManager), type(uint256).max);
        // mcalls = new MultiCall[](0);
        // creditFacade.liquidateCreditAccount(user1, user2, mcalls);

        // Liquidation method 2:
        //  Swap all WETH back to underlying (USDC), and pay the debt.
        //  Get remaining USDC.
        mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapExactTokensForTokens,
            (WETH.balanceOf(creditAccount), 0, path, address(0), block.timestamp)
        );
        creditFacade.liquidateCreditAccount(user1, user2, mcalls);
    }

    function _logBalance(address addr) internal {
        console.log("USDC: ", USDC.balanceOf(addr) * 1e4 / 10 ** IERC20Metadata(address(USDC)).decimals());
        console.log("WETH: ", WETH.balanceOf(addr) * 1e4 / 10 ** IERC20Metadata(address(WETH)).decimals());
    }
}
