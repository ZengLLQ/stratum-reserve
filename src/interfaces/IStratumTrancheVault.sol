// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStratumTrancheVault
 * @notice Interface for tokenized debt tranche vaults in StratumReserve.
 */
interface IStratumTrancheVault is IERC4626 {
    enum TrancheTier {
        SENIOR,
        MEZZANINE,
        JUNIOR
    }

    event YieldAccrued(uint256 amount, uint256 newTotalAssets);
    event LossAbsorbed(uint256 requestedLoss, uint256 actualAbsorbed, uint256 remainingAssets);
    event LiquidityDisbursed(address indexed recipient, uint256 amount);

    function tier() external view returns (TrancheTier);
    function targetAprBps() external view returns (uint256);
    function market() external view returns (address);
    function totalLossesAbsorbed() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);

    /**
     * @notice Disburses underlying liquidity to a borrower originated by StratumMarket.
     * @param amount Principal liquidity amount.
     * @param recipient Destination address of funds.
     */
    function disburseLiquidity(uint256 amount, address recipient) external;

    /**
     * @notice Distributes yield into the tranche via waterfall priority.
     * @param assetAmount Underlying asset amount injected.
     */
    function accrueYield(uint256 assetAmount) external;

    /**
     * @notice Absorbs default / haircut loss against the tranche's equity capital.
     * @param lossAmount Impairment amount in underlying assets.
     * @return absorbed Actual amount absorbed (bounded by current total assets).
     */
    function absorbLoss(uint256 lossAmount) external returns (uint256 absorbed);
}
