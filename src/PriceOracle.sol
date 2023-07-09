// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// import {IPriceFeedType} from "../interfaces/IPriceFeedType.sol";
// import {PriceFeedChecker} from "./PriceFeedChecker.sol";
// import {IPriceOracleV2} from "./interfaces/IPriceOracle.sol";

// // CONSTANTS

// // EXCEPTIONS
// import {
//     ZeroAddressException,
//     AddressIsNotContractException,
//     IncorrectPriceFeedException,
//     IncorrectTokenContractException
// } from "./interfaces/IErrors.sol";

// struct PriceFeedConfig {
//     address token;
//     address priceFeed;
// }

// uint256 constant SKIP_PRICE_CHECK_FLAG = 1 << 161;
// uint256 constant DECIMALS_SHIFT = 162;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Simplified: use simple oracle
contract SimplePriceOracle {
    error OnlyPriceFeedException();

    address public priceFeed;
    mapping(address => uint256) prices;

    modifier onlyPriceFeed() {
        if (msg.sender != priceFeed) revert OnlyPriceFeedException();
        _;
    }

    constructor() {
        priceFeed = msg.sender;
    }

    function setToUSD(address token, uint256 price) public onlyPriceFeed {
        prices[token] = price;
    }

    function convertToUSD(uint256 amount, address token) public view returns (uint256) {
        return amount * prices[token] / (10 ** IERC20Metadata(token).decimals());
    }

    function convertFromUSD(uint256 amount, address token) public view returns (uint256) {
        return amount * (10 ** IERC20Metadata(token).decimals()) / prices[token];
    }
}
