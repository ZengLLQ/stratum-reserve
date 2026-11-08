// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/libraries/StratumMath.sol";

contract StratumMathWrapper {
    function wadDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return StratumMath.wadDiv(a, b);
    }

    function rayDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return StratumMath.rayDiv(a, b);
    }
}

contract StratumMathTest is Test {
    using StratumMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    StratumMathWrapper internal wrapper;

    function setUp() public {
        wrapper = new StratumMathWrapper();
    }

    function test_WadMul_Identity() public pure {
        uint256 a = 5 * WAD;
        uint256 b = 1 * WAD;
        assertEq(StratumMath.wadMul(a, b), 5 * WAD);
    }

    function test_WadDiv_Identity() public pure {
        uint256 a = 10 * WAD;
        uint256 b = 2 * WAD;
        assertEq(StratumMath.wadDiv(a, b), 5 * WAD);
    }

    function test_WadDiv_ZeroDenominatorReverts() public {
        vm.expectRevert(StratumMath.StratumMath__ZeroDivision.selector);
        wrapper.wadDiv(10 * WAD, 0);
    }

    function test_RayMul_Identity() public pure {
        uint256 a = 7 * RAY;
        uint256 b = 1 * RAY;
        assertEq(StratumMath.rayMul(a, b), 7 * RAY);
    }

    function test_RayDiv_Identity() public pure {
        uint256 a = 21 * RAY;
        uint256 b = 3 * RAY;
        assertEq(StratumMath.rayDiv(a, b), 7 * RAY);
    }

    function test_RayDiv_ZeroDenominatorReverts() public {
        vm.expectRevert(StratumMath.StratumMath__ZeroDivision.selector);
        wrapper.rayDiv(10 * RAY, 0);
    }

    function test_WadToRay_And_RayToWad() public pure {
        uint256 wadVal = 123456789 * 1e10;
        uint256 rayVal = StratumMath.wadToRay(wadVal);
        assertEq(rayVal, wadVal * 1e9);
        assertEq(StratumMath.rayToWad(rayVal), wadVal);
    }

    function test_MulBps() public pure {
        uint256 amount = 1000 * WAD;
        uint256 result = StratumMath.mulBps(amount, 500); // 5%
        assertEq(result, 50 * WAD);
    }

    function test_CalculateBorrowRate_BelowKink() public pure {
        uint256 baseRate = 0.02e27; // 2%
        uint256 slope1 = 0.08e27; // 8%
        uint256 slope2 = 0.5e27; // 50%
        uint256 kink = 0.8e27; // 80%

        // 40% utilization (half of kink 80%)
        uint256 totalBorrowed = 400 * WAD;
        uint256 totalAssets = 1000 * WAD;

        uint256 rate = StratumMath.calculateBorrowRate(totalBorrowed, totalAssets, baseRate, slope1, slope2, kink);

        // Expected rate = 2% + (40% / 80%) * 8% = 2% + 4% = 6% = 0.06e27
        assertApproxEqAbs(rate, 0.06e27, 1e20);
    }

    function test_CalculateBorrowRate_AboveKink() public pure {
        uint256 baseRate = 0.02e27; // 2%
        uint256 slope1 = 0.08e27; // 8%
        uint256 slope2 = 0.5e27; // 50%
        uint256 kink = 0.8e27; // 80%

        // 90% utilization (halfway between 80% and 100%)
        uint256 totalBorrowed = 900 * WAD;
        uint256 totalAssets = 1000 * WAD;

        uint256 rate = StratumMath.calculateBorrowRate(totalBorrowed, totalAssets, baseRate, slope1, slope2, kink);

        // Expected rate = 2% + 8% + ((90% - 80%) / (100% - 80%)) * 50%
        // = 10% + 0.5 * 50% = 10% + 25% = 35% = 0.35e27
        assertApproxEqAbs(rate, 0.35e27, 1e20);
    }

    function test_CalculateCompoundedRate() public pure {
        uint256 ratePerYear = 0.1e27; // 10% APR
        uint256 timeDelta = 365 days;

        uint256 compFactor = StratumMath.calculateCompoundedRate(ratePerYear, timeDelta);
        // First order = 10%, second order = (0.1)^2 / 2 = 0.005 = 0.5% -> ~1.105e27
        assertApproxEqAbs(compFactor, 1.105e27, 1e22);
    }

    function test_CalculateHealthFactor() public pure {
        uint256 collateralValueUsd = 10_000 * WAD;
        uint256 totalDebtUsd = 7_500 * WAD;
        uint256 liquidationThresholdBps = 8_500; // 85%

        uint256 hf = StratumMath.calculateHealthFactor(collateralValueUsd, totalDebtUsd, liquidationThresholdBps);
        // Adjusted collateral = 10,000 * 0.85 = 8,500 USD
        // HF = 8,500 / 7,500 = 1.133333333333333333 WAD
        uint256 expectedHf = (8_500 * WAD) / 7_500;
        assertEq(hf, expectedHf);
    }

    function test_Fuzz_WadMulDiv(uint128 a, uint128 b) public pure {
        vm.assume(b >= 1e18 && b <= 1e28);
        vm.assume(a >= 1e18 && a <= 1e28);
        uint256 prod = StratumMath.wadMul(a, b);
        uint256 div = StratumMath.wadDiv(prod, b);
        assertApproxEqRel(div, a, 1e14); // 0.01% tolerance for 18-decimal fixed point rounding
    }
}
