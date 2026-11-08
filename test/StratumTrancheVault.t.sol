// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/vaults/StratumTrancheVault.sol";
import "../src/mock/MockERC20.sol";

contract StratumTrancheVaultTest is Test {
    MockERC20 internal asset;
    StratumTrancheVault internal seniorVault;
    StratumTrancheVault internal juniorVault;

    address internal market = address(0x1111);
    address internal alice = address(0xAAAA);
    address internal bob = address(0xBBBB);

    uint256 internal constant INITIAL_DEPOSIT = 10_000 * 1e18;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 18);

        seniorVault = new StratumTrancheVault(
            asset,
            "Stratum Senior AAA",
            "strSenior",
            IStratumTrancheVault.TrancheTier.SENIOR,
            600, // 6.00% target APR
            market
        );

        juniorVault = new StratumTrancheVault(
            asset,
            "Stratum Junior First-Loss",
            "strJunior",
            IStratumTrancheVault.TrancheTier.JUNIOR,
            1800, // 18.00% target APR
            market
        );

        asset.mint(alice, 100_000 * 1e18);
        asset.mint(bob, 100_000 * 1e18);

        vm.prank(alice);
        asset.approve(address(seniorVault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(juniorVault), type(uint256).max);
    }

    function test_InitialState() public view {
        assertEq(address(seniorVault.asset()), address(asset));
        assertEq(seniorVault.market(), market);
        assertEq(seniorVault.targetAprBps(), 600);
        assertEq(uint256(seniorVault.tier()), uint256(IStratumTrancheVault.TrancheTier.SENIOR));
        assertEq(seniorVault.totalAssets(), 0);
        assertEq(seniorVault.availableLiquidity(), 0);
    }

    function test_DepositAndWithdraw() public {
        vm.prank(alice);
        uint256 shares = seniorVault.deposit(INITIAL_DEPOSIT, alice);

        // Due to virtual shares (offset 3 = 1000 shares), shares > 0
        assertGt(shares, 0);
        assertEq(seniorVault.totalAssets(), INITIAL_DEPOSIT);
        assertEq(seniorVault.availableLiquidity(), INITIAL_DEPOSIT);

        // Alice withdraws half
        vm.prank(alice);
        seniorVault.withdraw(INITIAL_DEPOSIT / 2, alice, alice);

        assertEq(seniorVault.totalAssets(), INITIAL_DEPOSIT / 2);
        assertEq(seniorVault.availableLiquidity(), INITIAL_DEPOSIT / 2);
    }

    function test_InflationAttackMitigation() public {
        // Attacker deposits 1 wei
        vm.prank(alice);
        seniorVault.deposit(1, alice);

        // Attacker donates 1000 tokens directly
        asset.mint(address(seniorVault), 1000 * 1e18);

        // Victim deposits 1000 tokens
        vm.prank(bob);
        asset.approve(address(seniorVault), type(uint256).max);
        vm.prank(bob);
        uint256 bobShares = seniorVault.deposit(1000 * 1e18, bob);

        // Bob must receive non-zero shares despite donation attack (virtual shares protection)
        assertGt(bobShares, 0);

        // Bob withdraws and recovers substantially all his funds
        vm.prank(bob);
        uint256 redeemedAssets = seniorVault.redeem(bobShares, bob, bob);
        assertApproxEqAbs(redeemedAssets, 1000 * 1e18, 1e18);
    }

    function test_MarketDisburseLiquidity() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        address borrower = address(0xCCCC);
        uint256 borrowAmount = 6_000 * 1e18;

        vm.prank(market);
        seniorVault.disburseLiquidity(borrowAmount, borrower);

        assertEq(asset.balanceOf(borrower), borrowAmount);
        assertEq(seniorVault.activePrincipalLent(), borrowAmount);
        assertEq(seniorVault.availableLiquidity(), INITIAL_DEPOSIT - borrowAmount);
        // Total assets remains unchanged because activePrincipalLent is counted!
        assertEq(seniorVault.totalAssets(), INITIAL_DEPOSIT);
    }

    function test_MarketDisburseLiquidity_RevertsIfNotMarket() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        vm.expectRevert(StratumTrancheVault.StratumTrancheVault__OnlyMarket.selector);
        seniorVault.disburseLiquidity(1000 * 1e18, alice);
    }

    function test_MarketDisburseLiquidity_RevertsIfInsufficientLiquidity() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        vm.prank(market);
        vm.expectRevert(StratumTrancheVault.StratumTrancheVault__InsufficientLiquidity.selector);
        seniorVault.disburseLiquidity(INITIAL_DEPOSIT + 1, alice);
    }

    function test_MarketRepayPrincipal() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        address borrower = address(0xCCCC);
        vm.prank(market);
        seniorVault.disburseLiquidity(5_000 * 1e18, borrower);

        // Market repays 3,000 principal
        vm.prank(market);
        seniorVault.repayPrincipal(3_000 * 1e18);

        assertEq(seniorVault.activePrincipalLent(), 2_000 * 1e18);
    }

    function test_MarketAccrueYield() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        // Yield injection
        asset.mint(address(seniorVault), 500 * 1e18);
        vm.prank(market);
        seniorVault.accrueYield(500 * 1e18);

        assertEq(seniorVault.totalAssets(), INITIAL_DEPOSIT + 500 * 1e18);
    }

    function test_MarketAbsorbLoss() public {
        vm.prank(bob);
        juniorVault.deposit(INITIAL_DEPOSIT, bob);

        address borrower = address(0xCCCC);
        vm.prank(market);
        juniorVault.disburseLiquidity(4_000 * 1e18, borrower);

        // Borrower defaults on 2,500
        vm.prank(market);
        uint256 absorbed = juniorVault.absorbLoss(2_500 * 1e18);

        assertEq(absorbed, 2_500 * 1e18);
        assertEq(juniorVault.activePrincipalLent(), 1_500 * 1e18);
        assertEq(juniorVault.totalLossesAbsorbed(), 2_500 * 1e18);
        assertEq(juniorVault.totalAssets(), INITIAL_DEPOSIT - 2_500 * 1e18);
    }

    function test_MaxWithdrawBoundedByLiquidCash() public {
        vm.prank(alice);
        seniorVault.deposit(INITIAL_DEPOSIT, alice);

        // 8,000 lent out, only 2,000 liquid cash remains
        vm.prank(market);
        seniorVault.disburseLiquidity(8_000 * 1e18, address(0xCCCC));

        uint256 maxW = seniorVault.maxWithdraw(alice);
        assertEq(maxW, 2_000 * 1e18);
    }
}
