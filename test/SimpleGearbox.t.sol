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

        // Create pool
        interestRateModel = new LinearInterestRateModel(0, 0, 0, 0); // Simplified: neglect interest
        poolService = new PoolService(address(USDC), address(interestRateModel), type(uint256).max);

        creditManager = new CreditManager(address(poolService), address(USDC));
        poolService.connectCreditManager(address(creditManager));
        creditManager.setLiquidationThreshold(address(USDC), 1e4); // 100%

        creditFacade = new CreditFacade(address(creditManager));
        creditManager.upgradeCreditFacade(address(creditFacade));

        priceOracle = new SimplePriceOracle();
        creditManager.setPriceOracle(address(priceOracle));

        uniswapV2Adapter = new UniswapV2Adapter(address(creditManager), address(UNISWAP_V2_ROUTER));
        creditManager.changeContractAllowance(address(uniswapV2Adapter), address(UNISWAP_V2_ROUTER));

        creditManager.addToken(address(WETH));
        creditManager.setLiquidationThreshold(address(WETH), 9e3); // 90%
        creditManager.setLiquidationDiscount(8e3); // 20% off discount

        priceOracle.setToUSD(address(USDC), 1e8);
        priceOracle.setToUSD(address(WETH), 1800e8);

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

        vm.startPrank(user1);
        deal(address(USDC), user1, AMOUNT_OPEN_WITH, true);
        USDC.approve(address(creditManager), AMOUNT_OPEN_WITH);
        creditFacade.openCreditAccount(AMOUNT_OPEN_WITH, user1, LEVERAGE_RATIO);
        vm.stopPrank();

        address creditAccount = creditManager.getCreditAccountOrRevert(user1);

        assertEq(USDC.balanceOf(creditAccount), AMOUNT_OPEN_WITH * (1 + LEVERAGE_RATIO / LEVERAGE_DECIMALS));

        vm.startPrank(user1);
        MultiCall[] memory mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapExactTokensForTokens, (AMOUNT_OPEN_WITH * 5, 0, path, address(0), block.timestamp)
        );
        creditFacade.multicall(mcalls);

        // Assume user1 earn lots of usdc and decide to close the account
        deal(address(USDC), creditAccount, 5100000000);
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
        vm.stopPrank();

        address creditAccount = creditManager.getCreditAccountOrRevert(user1);

        assertEq(USDC.balanceOf(creditAccount), AMOUNT_OPEN_WITH * (1 + LEVERAGE_RATIO / LEVERAGE_DECIMALS));

        vm.startPrank(user1);
        MultiCall[] memory mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapExactTokensForTokens, (AMOUNT_OPEN_WITH * 5, 0, path, address(0), block.timestamp)
        );
        creditFacade.multicall(mcalls);

        // Lower eth price to test liquidate
        assert(creditFacade.calcCreditAccountHealthFactor(creditAccount) > 1e4);
        changePrank(admin);
        priceOracle.setToUSD(address(WETH), 1600 * 1e8);
        assert(creditFacade.calcCreditAccountHealthFactor(creditAccount) < 1e4);

        changePrank(user2);
        deal(address(USDC), user2, 100000e6);
        USDC.approve(address(creditManager), type(uint256).max); //
        _logBalance(user2);

        mcalls = new MultiCall[](1);
        mcalls[0].target = address(uniswapV2Adapter);
        path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);
        mcalls[0].callData = abi.encodeCall(
            UniswapV2Adapter.swapTokensForExactTokens,
            (AMOUNT_OPEN_WITH * 4, type(uint256).max, path, address(0), block.timestamp)
        );
        creditFacade.liquidateCreditAccount(user1, user2, mcalls);
        _logBalance(user2);
    }

    function _logBalance(address addr) internal {
        console.log("USDC: ", USDC.balanceOf(addr) * 1e4 / 10 ** IERC20Metadata(address(USDC)).decimals());
        console.log("WETH: ", WETH.balanceOf(addr) * 1e4 / 10 ** IERC20Metadata(address(WETH)).decimals());
    }
}
