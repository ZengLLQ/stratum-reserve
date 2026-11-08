// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IPriceOracle.sol";
import "./IStratumTrancheVault.sol";

/**
 * @title IStratumMarket
 * @notice Interface for the central credit origination and waterfall settlement market.
 */
interface IStratumMarket {
    struct CollateralConfig {
        bool isWhitelisted;
        uint256 ltvBps; // e.g. 7500 = 75%
        uint256 liquidationThresholdBps; // e.g. 8500 = 85%
        uint256 liquidationBonusBps; // e.g. 800 = 8% bonus for liquidators
    }

    struct Loan {
        uint256 id;
        address borrower;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 principalBorrowed;
        uint256 interestAccrued;
        uint256 seniorPrincipal;
        uint256 mezzaninePrincipal;
        uint256 juniorPrincipal;
        uint256 startTimestamp;
        uint256 lastAccrualTimestamp;
        uint256 maturityTimestamp;
        bool isClosed;
        bool isDefaulted;
    }

    event CollateralConfigured(
        address indexed collateralAsset,
        bool isWhitelisted,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
    );

    event LoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 collateralAmount,
        uint256 principalBorrowed,
        uint256 maturityTimestamp
    );

    event InterestAccrued(uint256 indexed loanId, uint256 interestDelta, uint256 totalInterestAccrued);

    event LoanRepaid(
        uint256 indexed loanId,
        address indexed payer,
        uint256 amountRepaid,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 remainingDebt
    );

    event WaterfallDistributed(
        uint256 indexed loanId, uint256 treasuryFee, uint256 seniorYield, uint256 mezzanineYield, uint256 juniorYield
    );

    event LoanLiquidated(
        uint256 indexed loanId,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 remainingCollateral
    );

    event BadDebtWrittenOff(
        uint256 indexed loanId,
        uint256 totalBadDebt,
        uint256 juniorAbsorbed,
        uint256 mezzanineAbsorbed,
        uint256 seniorAbsorbed
    );

    function oracle() external view returns (IPriceOracle);
    function underlyingAsset() external view returns (IERC20);
    function seniorVault() external view returns (IStratumTrancheVault);
    function mezzanineVault() external view returns (IStratumTrancheVault);
    function juniorVault() external view returns (IStratumTrancheVault);
    function treasury() external view returns (address);

    function getLoan(uint256 loanId) external view returns (Loan memory);
    function getLoanHealthFactor(uint256 loanId) external view returns (uint256 healthFactor);
    function getLoanTotalDebt(uint256 loanId) external view returns (uint256 totalDebt);

    function accrueInterest(uint256 loanId) external;
    function liquidateLoan(uint256 loanId, uint256 debtToRepay) external;
}
