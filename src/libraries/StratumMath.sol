// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title StratumMath
 * @notice Fixed-point Wad (1e18) and Ray (1e27) arithmetic, utilization curve formulas,
 *         and credit risk waterfall calculation utilities for StratumReserve.
 */
library StratumMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;
    uint256 internal constant BPS_DIVISOR = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    error StratumMath__ZeroDivision();
    error StratumMath__Overflow();

    /// @notice Multiplies two WAD numbers with rounding to half.
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_WAD) / WAD;
    }

    /// @notice Divides two WAD numbers with rounding to half.
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert StratumMath__ZeroDivision();
        if (a == 0) return 0;
        return (a * WAD + b / 2) / b;
    }

    /// @notice Multiplies two RAY numbers with rounding to half.
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    /// @notice Divides two RAY numbers with rounding to half.
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert StratumMath__ZeroDivision();
        if (a == 0) return 0;
        return (a * RAY + b / 2) / b;
    }

    /// @notice Converts WAD to RAY.
    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * 1e9;
    }

    /// @notice Converts RAY to WAD with rounding.
    function rayToWad(uint256 a) internal pure returns (uint256) {
        return (a + 0.5e9) / 1e9;
    }

    /// @notice Multiplies an amount by basis points (1 bps = 0.01%).
    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DIVISOR;
    }

    /**
     * @notice Computes interest rate based on a dual-kink piecewise linear utilization model.
     * @param totalBorrowed Total outstanding borrowed assets.
     * @param totalAssets Total liquidity in the pool (cash + borrowed).
     * @param baseRate Annual base interest rate in Ray.
     * @param slope1 Annual interest rate slope below kink in Ray.
     * @param slope2 Annual interest rate jump slope above kink in Ray.
     * @param kink Utilization threshold where slope transitions (in Ray, e.g. 0.8e27 for 80%).
     * @return borrowRatePerYear Annual borrow rate in Ray.
     */
    function calculateBorrowRate(
        uint256 totalBorrowed,
        uint256 totalAssets,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 kink
    ) internal pure returns (uint256 borrowRatePerYear) {
        if (totalAssets == 0 || totalBorrowed == 0) {
            return baseRate;
        }

        uint256 utilization = rayDiv(totalBorrowed * RAY, totalAssets * RAY);

        if (utilization <= kink) {
            // Rate = Base + (Utilization / Kink) * Slope1
            uint256 ratio = rayDiv(utilization, kink);
            borrowRatePerYear = baseRate + rayMul(ratio, slope1);
        } else {
            // Rate = Base + Slope1 + ((Utilization - Kink) / (1 - Kink)) * Slope2
            uint256 excessUtilization = utilization - kink;
            uint256 remainingRange = RAY - kink;
            uint256 excessRatio = rayDiv(excessUtilization, remainingRange);
            borrowRatePerYear = baseRate + slope1 + rayMul(excessRatio, slope2);
        }
    }

    /**
     * @notice Compounded interest factor for a given time delta using binomial expansion:
     *         (1 + r * dt) with first-order and second-order Taylor terms.
     * @param ratePerYear Annual rate in Ray.
     * @param timeDelta Elapsed time in seconds.
     * @return compFactor Cumulative compounding multiplier in Ray.
     */
    function calculateCompoundedRate(uint256 ratePerYear, uint256 timeDelta)
        internal
        pure
        returns (uint256 compFactor)
    {
        if (timeDelta == 0 || ratePerYear == 0) {
            return RAY;
        }

        // Multiply before divide to maintain maximum numerical precision
        uint256 firstOrder = (ratePerYear * timeDelta) / SECONDS_PER_YEAR;
        // Second order term: (firstOrder)^2 / (2 * RAY)
        uint256 secondOrder = rayMul(firstOrder, firstOrder) / 2;

        compFactor = RAY + firstOrder + secondOrder;
    }

    /**
     * @notice Evaluates loan health factor.
     *         HealthFactor = (CollateralValue * LiquidationThreshold) / TotalDebt
     * @param collateralValueUsd Total collateral value normalized to 18 decimals USD.
     * @param totalDebtUsd Total debt value normalized to 18 decimals USD.
     * @param liquidationThresholdBps Threshold in bps (e.g. 8500 = 85%).
     * @return healthFactor Health factor scaled by WAD (1e18 = 1.0).
     */
    function calculateHealthFactor(uint256 collateralValueUsd, uint256 totalDebtUsd, uint256 liquidationThresholdBps)
        internal
        pure
        returns (uint256 healthFactor)
    {
        if (totalDebtUsd == 0) {
            return type(uint256).max;
        }
        uint256 adjustedCollateral = mulBps(collateralValueUsd, liquidationThresholdBps);
        healthFactor = wadDiv(adjustedCollateral, totalDebtUsd);
    }
}
