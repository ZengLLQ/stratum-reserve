// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/market/StratumMarket.sol";
import "../src/liquidation/StratumDutchAuction.sol";
import "../src/vaults/StratumTrancheVault.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockPriceOracle.sol";

contract StratumDutchAuctionTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockPriceOracle internal oracle;

    StratumTrancheVault internal seniorVault;
    StratumTrancheVault internal mezzanineVault;
    StratumTrancheVault internal juniorVault;
    StratumMarket internal market;
    StratumDutchAuction internal auctionEngine;

    address internal treasury = address(0x9999);
    address internal borrower = address(0x2222);
    address internal bidder = address(0x7777);

    uint256 internal constant WETH_PRICE = 3_000 * 1e18;
    uint256 internal constant USDC_PRICE = 1 * 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockPriceOracle();

        oracle.setAssetPrice(address(weth), WETH_PRICE, 18);
        oracle.setAssetPrice(address(usdc), USDC_PRICE, 18);

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

        auctionEngine = new StratumDutchAuction(address(market), address(usdc));

        // Fund tranches
        usdc.mint(address(seniorVault), 500_000 * 1e18);
        usdc.mint(address(mezzanineVault), 200_000 * 1e18);
        usdc.mint(address(juniorVault), 100_000 * 1e18);

        // Fund borrower with WETH
        weth.mint(borrower, 20 * 1e18);
        vm.prank(borrower);
        weth.approve(address(market), type(uint256).max);

        // Fund bidder with USDC
        usdc.mint(bidder, 500_000 * 1e18);
        vm.prank(bidder);
        usdc.approve(address(auctionEngine), type(uint256).max);
    }

    function test_DutchAuction_FullLifecycle() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 20_000 * 1e18, 30 days);

        // Drop price to trigger liquidatable state (HF < 1.0)
        oracle.setAssetPrice(address(weth), 2_200 * 1e18, 18);

        uint256 startPrice = 2_400 * 1e18; // Premium start price
        uint256 floorPrice = 1_800 * 1e18; // Floor reserve price
        uint256 duration = 3600; // 1 hour decay

        uint256 auctionId = auctionEngine.startAuction(loanId, startPrice, floorPrice, duration);
        assertEq(auctionId, 1);

        // At t = 0, price is startPrice
        assertEq(auctionEngine.getCurrentPrice(auctionId), startPrice);

        // Warp to 30 minutes (half duration)
        vm.warp(block.timestamp + 1800);
        uint256 midPrice = auctionEngine.getCurrentPrice(auctionId);
        assertEq(midPrice, 2_100 * 1e18);

        // Warp past end of duration (total elapsed 3601 seconds)
        vm.warp(block.timestamp + 1801);
        assertEq(auctionEngine.getCurrentPrice(auctionId), floorPrice);

        // Bidder buys collateral and settles debt
        vm.prank(bidder);
        auctionEngine.buyCollateral(auctionId);

        // Auction is marked settled
        assertEq(auctionEngine.getCurrentPrice(auctionId), 0);

        // Loan in market is closed!
        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        assertTrue(loan.isClosed);
    }

    function test_DutchAuction_RevertsIfLoanHealthy() public {
        vm.prank(borrower);
        uint256 loanId = market.borrow(address(weth), 10 * 1e18, 15_000 * 1e18, 30 days);

        // Loan is healthy (HF = 1.7)
        vm.expectRevert(StratumDutchAuction.StratumDutchAuction__LoanNotLiquidatable.selector);
        auctionEngine.startAuction(loanId, 3_200 * 1e18, 2_500 * 1e18, 3600);
    }

    function test_DutchAuction_RevertsIfInvalidPriceBounds() public {
        vm.expectRevert(StratumDutchAuction.StratumDutchAuction__InvalidPriceBounds.selector);
        auctionEngine.startAuction(1, 1_000 * 1e18, 2_000 * 1e18, 3600);
    }
}
