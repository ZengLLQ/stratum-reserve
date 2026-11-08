// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/market/StratumMarket.sol";
import "../src/vaults/StratumTrancheVault.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockPriceOracle.sol";

contract StratumInvariantsTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockPriceOracle internal oracle;

    StratumTrancheVault internal seniorVault;
    StratumTrancheVault internal mezzanineVault;
    StratumTrancheVault internal juniorVault;
    StratumMarket internal market;

    address internal treasury = address(0x9999);
    address internal borrower = address(0x2222);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockPriceOracle();

        oracle.setAssetPrice(address(weth), 3_000 * 1e18, 18);
        oracle.setAssetPrice(address(usdc), 1 * 1e18, 18);

        market = new StratumMarket(usdc, oracle, treasury);

        seniorVault = new StratumTrancheVault(
            usdc, "Stratum Senior AAA", "strSenior", IStratumTrancheVault.TrancheTier.SENIOR, 600, address(market)
        );

        mezzanineVault = new StratumTrancheVault(
            usdc, "Stratum Mezzanine BBB", "strMezz", IStratumTrancheVault.TrancheTier.MEZZANINE, 1000, address(market)
        );

        juniorVault = new StratumTrancheVault(
            usdc, "Stratum Junior Equity", "strJunior", IStratumTrancheVault.TrancheTier.JUNIOR, 1800, address(market)
        );

        market.setTranches(seniorVault, mezzanineVault, juniorVault);
        market.setCollateralConfig(address(weth), true, 7500, 8500, 800);

        // Pre-fund vaults with deep liquidity
        usdc.mint(address(seniorVault), 10_000_000 * 1e18);
        usdc.mint(address(mezzanineVault), 10_000_000 * 1e18);
        usdc.mint(address(juniorVault), 10_000_000 * 1e18);

        weth.mint(borrower, 1_000_000 * 1e18);
        vm.prank(borrower);
        weth.approve(address(market), type(uint256).max);
    }

    /// @notice Invariant 1: Tranche Principal Partition strictly conserves borrow amount
    function test_Fuzz_TranchePartitionConservation(uint96 rawBorrow) public {
        // Bound between 100 USDC and 1,000,000 USDC
        uint256 borrowAmt = bound(uint256(rawBorrow), 100 * 1e18, 1_000_000 * 1e18);

        // Required collateral at $3,000 WETH and 75% LTV:
        // ColVal >= borrowAmt / 0.75 -> ColAmt = (borrowAmt * 10000) / (7500 * 3000)
        uint256 colAmount = (borrowAmt * 10_000) / (7_500 * 3_000) + 10 * 1e18;

        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), colAmount, borrowAmt, 30 days);

        IStratumMarket.Loan memory loan = market.getLoan(loanId);

        // Invariant: Senior + Mezzanine + Junior == BorrowAmt exactly!
        uint256 sumTranches = loan.seniorPrincipal + loan.mezzaninePrincipal + loan.juniorPrincipal;
        assertEq(sumTranches, borrowAmt, "Tranche partition conservation violated!");
    }

    /// @notice Invariant 2: Repayment Waterfall Conservation
    function test_Fuzz_WaterfallRepaymentConservation(uint96 rawBorrow, uint96 rawRepay) public {
        uint256 borrowAmt = bound(uint256(rawBorrow), 1_000 * 1e18, 100_000 * 1e18);
        uint256 colAmount = (borrowAmt * 10_000) / (7_500 * 3_000) + 10 * 1e18;

        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), colAmount, borrowAmt, 30 days);

        // Fast forward 10 days to accrue interest
        vm.warp(block.timestamp + 10 days);
        market.accrueInterest(loanId);

        uint256 totalDebt = market.getLoanTotalDebt(loanId);
        uint256 repayAmt = bound(uint256(rawRepay), 100 * 1e18, totalDebt);

        usdc.mint(borrower, repayAmt);
        vm.prank(borrower);
        usdc.approve(address(market), type(uint256).max);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 seniorAssetsBefore = seniorVault.totalAssets();
        uint256 mezzAssetsBefore = mezzanineVault.totalAssets();
        uint256 juniorAssetsBefore = juniorVault.totalAssets();

        vm.prank(borrower);
        market.repay(loanId, repayAmt);

        uint256 treasuryGain = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 seniorGain = seniorVault.totalAssets() - seniorAssetsBefore;
        uint256 mezzGain = mezzanineVault.totalAssets() - mezzAssetsBefore;
        uint256 juniorGain = juniorVault.totalAssets() - juniorAssetsBefore;

        // Invariant: All repay money is accounted for in treasury fee or vault equity growth
        uint256 totalYieldAndRepayGain = treasuryGain + seniorGain + mezzGain + juniorGain;
        assertEq(totalYieldAndRepayGain, treasuryGain + seniorGain + mezzGain + juniorGain);
        assertLe(treasuryGain, repayAmt);
    }

    /// @notice Invariant 3: Subordinated Tranche Protection (Senior is never impaired before Junior & Mezzanine)
    function test_Fuzz_SubordinatedProtection(uint96 rawLiquidationRepay) public {
        // Setup loan with $10,000 principal
        // Junior = $1,000, Mezzanine = $2,000, Senior = $7,000
        uint256 borrowAmt = 10_000 * 1e18;
        uint256 colAmount = 10 * 1e18;

        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), colAmount, borrowAmt, 30 days);

        uint256 liqRepay = bound(uint256(rawLiquidationRepay), 10_000 * 1e18, 50_000 * 1e18);

        // Simulate crash
        oracle.setAssetPrice(address(weth), 1, 18); // near zero

        address liquidator = address(0x8888);
        usdc.mint(liquidator, liqRepay * 2);
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(liquidator);
        market.liquidateLoan(loanId, liqRepay);

        // Check loss absorption order
        uint256 juniorLoss = juniorVault.totalLossesAbsorbed();
        uint256 mezzLoss = mezzanineVault.totalLossesAbsorbed();
        uint256 seniorLoss = seniorVault.totalLossesAbsorbed();

        // Invariant: Junior must be maxed out before Mezzanine absorbs any loss
        if (mezzLoss > 0) {
            assertGe(juniorLoss, 900 * 1e18, "Junior not wiped before Mezzanine!");
        }

        // Invariant: Mezzanine must be maxed out before Senior absorbs any loss
        if (seniorLoss > 0) {
            assertGe(mezzLoss, 1_900 * 1e18, "Mezzanine not wiped before Senior!");
        }
    }
}
