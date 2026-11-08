// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/market/StratumMarket.sol";
import "../src/vaults/StratumTrancheVault.sol";
import "../src/liquidation/StratumDutchAuction.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockPriceOracle.sol";

contract DeployStratumReserve is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy Test Tokens
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // 2. Deploy Oracle and Set Prices
        MockPriceOracle oracle = new MockPriceOracle();
        oracle.setAssetPrice(address(weth), 3_000 * 1e18, 18); // $3,000 WETH
        oracle.setAssetPrice(address(usdc), 1 * 1e18, 18); // $1 USDC

        address treasury = msg.sender;

        // 3. Deploy Market Controller
        StratumMarket market = new StratumMarket(usdc, oracle, treasury);

        // 4. Deploy 3 Tranche Vaults
        StratumTrancheVault seniorVault = new StratumTrancheVault(
            usdc,
            "Stratum Senior AAA",
            "strSenior",
            IStratumTrancheVault.TrancheTier.SENIOR,
            600, // 6% APR
            address(market)
        );

        StratumTrancheVault mezzanineVault = new StratumTrancheVault(
            usdc,
            "Stratum Mezzanine BBB",
            "strMezz",
            IStratumTrancheVault.TrancheTier.MEZZANINE,
            1000, // 10% APR
            address(market)
        );

        StratumTrancheVault juniorVault = new StratumTrancheVault(
            usdc,
            "Stratum Junior Equity",
            "strJunior",
            IStratumTrancheVault.TrancheTier.JUNIOR,
            1800, // 18% APR target
            address(market)
        );

        // 5. Connect Tranches to Market
        market.setTranches(seniorVault, mezzanineVault, juniorVault);

        // 6. Configure Collateral Risk Parameters (75% LTV, 85% Threshold, 8% Liquidation Bonus)
        market.setCollateralConfig(address(weth), true, 7500, 8500, 800);

        // 7. Deploy Dutch Auction Liquidation Engine
        StratumDutchAuction auction = new StratumDutchAuction(address(market), address(usdc));

        // 8. Seed Initial Protocol Liquidity for Demonstration
        usdc.mint(msg.sender, 1_000_000 * 1e18);
        usdc.approve(address(seniorVault), 700_000 * 1e18);
        seniorVault.deposit(700_000 * 1e18, msg.sender);

        usdc.approve(address(mezzanineVault), 200_000 * 1e18);
        mezzanineVault.deposit(200_000 * 1e18, msg.sender);

        usdc.approve(address(juniorVault), 100_000 * 1e18);
        juniorVault.deposit(100_000 * 1e18, msg.sender);

        vm.stopBroadcast();

        console2.log("=== StratumReserve Deployed Successfully ===");
        console2.log("Market:          ", address(market));
        console2.log("Senior Vault:    ", address(seniorVault));
        console2.log("Mezzanine Vault: ", address(mezzanineVault));
        console2.log("Junior Vault:    ", address(juniorVault));
        console2.log("Dutch Auction:   ", address(auction));
        console2.log("Oracle:          ", address(oracle));
        console2.log("USDC Token:      ", address(usdc));
        console2.log("WETH Collateral: ", address(weth));
    }
}
