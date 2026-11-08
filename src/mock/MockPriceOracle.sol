// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Controllable mock price oracle for unit testing and local deployment simulations.
 */
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public assetPrices;
    mapping(address => uint8) public assetDecimals;

    event PriceUpdated(address indexed asset, uint256 newPrice, uint8 decimals);

    function setAssetPrice(address asset, uint256 priceInUsd, uint8 decimals) external {
        assetPrices[asset] = priceInUsd;
        assetDecimals[asset] = decimals;
        emit PriceUpdated(asset, priceInUsd, decimals);
    }

    function getAssetPrice(address asset) external view override returns (uint256 priceInUsd, uint8 decimals) {
        priceInUsd = assetPrices[asset];
        decimals = assetDecimals[asset];
        if (priceInUsd == 0) {
            priceInUsd = 1e18; // fallback 1 USD
            decimals = 18;
        }
    }
}
