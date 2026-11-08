// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IPriceOracle
 * @notice Standard interface for StratumReserve price oracles returning asset valuations in USD.
 */
interface IPriceOracle {
    /**
     * @notice Returns price of an asset normalized to 18 decimals in USD (1 USD = 1e18).
     * @param asset Address of the ERC20 asset.
     * @return priceInUsd Price scaled by 1e18.
     * @return decimals Native decimals of the asset.
     */
    function getAssetPrice(address asset) external view returns (uint256 priceInUsd, uint8 decimals);
}
