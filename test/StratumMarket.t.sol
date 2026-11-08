// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/market/StratumMarket.sol";
import "../src/vaults/StratumTrancheVault.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockPriceOracle.sol";

contract StratumMarketTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockPriceOracle internal oracle;

    StratumTrancheVault internal seniorVault;
    StratumTrancheVault internal mezzanineVault;
    StratumTrancheVault internal juniorVault;
    StratumMarket internal market;

    address internal treasury = address(0x9999);
    address internal borrower = address(0x2222);
    address internal liquidator = address(0x3333);
    address internal lpSenior = address(0x4444);
    address internal lpMezz = address(0x5555);
    address internal lpJunior = address(0x6666);

    uint256 internal constant WETH_PRICE = 3_000 * 1e18; // 3,000 USD
    uint256 internal constant USDC_PRICE = 1 * 1e18; // 1 USD

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockPriceOracle();

        oracle.setAssetPrice(address(weth), WETH_PRICE, 18);
        oracle.setAssetPrice(address(usdc), USDC_PRICE, 18);

        market = new StratumMarket(usdc, oracle, treasury);

        seniorVault = new StratumTrancheVault(
            usdc,
            "Stratum Senior AAA",
            "strSenior",
            IStratumTrancheVault.TrancheTier.SENIOR,
            600, // 6% APR
            address(market)
        );

        mezzanineVault = new StratumTrancheVault(
            usdc,
            "Stratum Mezzanine BBB",
            "strMezz",
            IStratumTrancheVault.TrancheTier.MEZZANINE,
            1000, // 10% APR
            address(market)
        );

        juniorVault = new StratumTrancheVault(
            usdc,
            "Stratum Junior Equity",
            "strJunior",
            IStratumTrancheVault.TrancheTier.JUNIOR,
            1800, // 18% APR target
            address(market)
        );

        market.setTranches(seniorVault, mezzanineVault, juniorVault);

        // Configure WETH collateral: 75% LTV, 85% Liquidation Threshold, 8% Liquidation Bonus
        market.setCollateralConfig(address(weth), true, 7500, 8500, 800);

        // Seed liquidity from LPs into tranches
        usdc.mint(lpSenior, 1_000_000 * 1e18);
        usdc.mint(lpMezz, 500_000 * 1e18);
        usdc.mint(lpJunior, 250_000 * 1e18);

        vm.prank(lpSenior);
        usdc.approve(address(seniorVault), type(uint256).max);
        vm.prank(lpSenior);
        seniorVault.deposit(700_000 * 1e18, lpSenior);

        vm.prank(lpMezz);
        usdc.approve(address(mezzanineVault), type(uint256).max);
        vm.prank(lpMezz);
        mezzanineVault.deposit(200_000 * 1e18, lpMezz);

        vm.prank(lpJunior);
        usdc.approve(address(juniorVault), type(uint256).max);
        vm.prank(lpJunior);
        juniorVault.deposit(100_000 * 1e18, lpJunior);

        // Fund borrower with WETH collateral
        weth.mint(borrower, 100 * 1e18);
        vm.prank(borrower);
        weth.approve(address(market), type(uint256).max);

        // Fund liquidator with USDC
        usdc.mint(liquidator, 500_000 * 1e18);
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);
    }

    function test_Borrow_SuccessfulTrancheAllocation() public {
        uint256 colAmount = 10 * 1e18;
        uint256 borrowAmt = 20_000 * 1e18;
        uint256 term = 30 days;

        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), colAmount, borrowAmt, term);

        assertEq(loanId, 1);
        assertEq(usdc.balanceOf(borrower), borrowAmt);

        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.collateralAmount, colAmount);
        assertEq(loan.principalBorrowed, borrowAmt);

        // Capital stack partitioning: 70% Senior ($14,000), 20% Mezzanine ($4,000), 10% Junior ($2,000)
        assertEq(loan.seniorPrincipal, 14_000 * 1e18);
        assertEq(loan.mezzaninePrincipal, 4_000 * 1e18);
        assertEq(loan.juniorPrincipal, 2_000 * 1e18);

        // Vaults active principal tracking
        assertEq(seniorVault.activePrincipalLent(), 14_000 * 1e18);
        assertEq(mezzanineVault.activePrincipalLent(), 4_000 * 1e18);
        assertEq(juniorVault.activePrincipalLent(), 2_000 * 1e18);

        // Health factor
        uint256 hf = market.getLoanHealthFactor(loanId);
        assertEq(hf, 1.275 * 1e18);
    }

    function test_Borrow_RevertsIfExceedsMaxLtv() public {
        vm.prank(borrower);
        vm.expectRevert(StratumMarket.StratumMarket__ExceedsMaxLtv.selector);
        market.borrow(address(weth), 10 * 1e18, 23_000 * 1e18, 30 days);
    }

    function test_Borrow_RevertsIfCollateralNotWhitelisted() public {
        MockERC20 unwhitelisted = new MockERC20("Fake", "FK", 18);
        unwhitelisted.mint(borrower, 100 * 1e18);
        vm.prank(borrower);
        unwhitelisted.approve(address(market), type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(StratumMarket.StratumMarket__CollateralNotWhitelisted.selector);
        market.borrow(address(unwhitelisted), 10 * 1e18, 5_000 * 1e18, 30 days);
    }

    function test_InterestAccrual() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 20_000 * 1e18, 365 days);

        // Fast forward 180 days (half a year)
        vm.warp(block.timestamp + 180 days);

        market.accrueInterest(loanId);
        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertGt(loan.interestAccrued, 0);
    }

    function test_WaterfallRepayment_FullSettlement() public {
        // Set borrow interest rate higher (base 20% APR) to test yield flowing through all tranches
        market.setInterestRateParams(0.2e27, 0.08e27, 0.5e27, 0.8e27);

        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 20_000 * 1e18, 365 days);

        // Fast forward 180 days
        vm.warp(block.timestamp + 180 days);
        market.accrueInterest(loanId);

        uint256 totalDebt = market.getLoanTotalDebt(loanId);
        assertGt(totalDebt, 20_000 * 1e18);

        // Borrower gets additional USDC to repay accrued interest
        usdc.mint(borrower, 10_000 * 1e18);
        vm.prank(borrower);
        usdc.approve(address(market), type(uint256).max);

        // Record initial balances before repay
        uint256 seniorAssetsBefore = seniorVault.totalAssets();
        uint256 mezzAssetsBefore = mezzanineVault.totalAssets();
        uint256 juniorAssetsBefore = juniorVault.totalAssets();

        // Repay total debt
        vm.prank(borrower);
        market.repay(loanId, totalDebt);

        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertTrue(loan.isClosed);
        assertEq(loan.principalBorrowed, 0);
        assertEq(loan.interestAccrued, 0);
        assertEq(loan.collateralAmount, 0);

        // 10 WETH collateral was returned to borrower!
        assertEq(weth.balanceOf(borrower), 100 * 1e18);

        // Verify Waterfall:
        // Treasury received fee
        assertGt(usdc.balanceOf(treasury), 0);
        // All tranches grew in asset value from accrued yield!
        assertGt(seniorVault.totalAssets(), seniorAssetsBefore);
        assertGt(mezzanineVault.totalAssets(), mezzAssetsBefore);
        assertGt(juniorVault.totalAssets(), juniorAssetsBefore);
    }

    function test_Liquidation_WhenPriceDrops() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 20_000 * 1e18, 30 days);

        // Price drops from $3,000 to $2,300.
        // 10 WETH = $23,000. At 85% threshold, adjusted collateral = $19,550.
        // Debt = $20,000. Health Factor = $19,550 / $20,000 = 0.9775 (< 1.0 -> liquidatable!)
        oracle.setAssetPrice(address(weth), 2_300 * 1e18, 18);

        uint256 hf = market.getLoanHealthFactor(loanId);
        assertLt(hf, 1e18);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        // Liquidator clears half the debt ($10,000)
        vm.prank(liquidator);
        market.liquidateLoan(loanId, 10_000 * 1e18);

        // Liquidator received seized WETH collateral at 8% bonus
        uint256 wethSeized = weth.balanceOf(liquidator) - liquidatorWethBefore;
        assertGt(wethSeized, 0);

        // Remaining debt is now ~10,000
        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertApproxEqAbs(loan.principalBorrowed, 10_000 * 1e18, 1e18);
    }

    function test_ReverseLossWaterfall_BadDebtAbsorption() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 20_000 * 1e18, 30 days);

        // Catastrophic flash crash: WETH crashes to $100
        oracle.setAssetPrice(address(weth), 100 * 1e18, 18);

        uint256 juniorAssetsBefore = juniorVault.totalAssets();
        uint256 mezzAssetsBefore = mezzanineVault.totalAssets();

        // Liquidator liquidates all available collateral ($1,000 value)
        vm.prank(liquidator);
        market.liquidateLoan(loanId, 25_000 * 1e18);

        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertTrue(loan.isDefaulted);
        assertTrue(loan.isClosed);
        assertEq(loan.collateralAmount, 0);

        // Bad debt was written off in reverse waterfall:
        // Junior tranche absorbed first loss and was wiped of its remaining principal (~$1,907)
        assertApproxEqAbs(juniorVault.totalLossesAbsorbed(), 1_907.4e18, 1e18);
        assertApproxEqAbs(juniorVault.totalAssets(), juniorAssetsBefore - 1_907.4e18, 1e18);

        // Mezzanine absorbed next loss (~$3,814)
        assertApproxEqAbs(mezzanineVault.totalLossesAbsorbed(), 3_814.8e18, 1e18);
        assertApproxEqAbs(mezzanineVault.totalAssets(), mezzAssetsBefore - 3_814.8e18, 1e18);

        // Senior only absorbed remaining bad debt
        assertGt(seniorVault.totalLossesAbsorbed(), 0);
    }

    function test_Liquidation_WhenExpiredPastMaturity() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 15_000 * 1e18, 10 days);

        // Fast forward 15 days (5 days past maturity)
        vm.warp(block.timestamp + 15 days);

        // Loan is liquidatable due to expiry even if price didn't drop
        vm.prank(liquidator);
        market.liquidateLoan(loanId, 5_000 * 1e18);

        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertLt(loan.principalBorrowed, 15_000 * 1e18);
    }
}
