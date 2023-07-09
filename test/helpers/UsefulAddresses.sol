// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV2Router01} from "v2-periphery/interfaces/IUniswapV2Router01.sol";

contract UsefulAddresses is Test {
    IUniswapV2Router01 public constant UNISWAP_V2_ROUTER =
        IUniswapV2Router01(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public constant GEAR = IERC20(0xBa3335588D9403515223F109EdC4eB7269a9Ab5D);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 public constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    IERC20 public constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IERC20 public constant COMP = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);

    function labelAddress() public {
        vm.label(address(UNISWAP_V2_ROUTER), "uniswapV2Router");
        vm.label(address(USDC), "usdc");
        vm.label(address(DAI), "dai");
        vm.label(address(GEAR), "gear");
        vm.label(address(WETH), "weth");
        vm.label(address(WBTC), "wbtc");
        vm.label(address(LINK), "link");
        vm.label(address(UNI), "uni");
        vm.label(address(COMP), "comp");
    }
}
