// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IStratumTrancheVault.sol";

/**
 * @title StratumTrancheVault
 * @notice ERC-4626 compliant tokenized debt vault representing a distinct risk-return tier
 *         (Senior AAA, Mezzanine BBB, or Junior First-Loss Equity).
 */
contract StratumTrancheVault is ERC4626, Ownable, IStratumTrancheVault {
    using SafeERC20 for IERC20;

    TrancheTier public immutable override tier;
    uint256 public immutable override targetAprBps;
    address public immutable override market;

    /// @notice Principal capital of this vault currently lent out in active loans
    uint256 public activePrincipalLent;

    /// @notice Cumulative default losses absorbed by this tranche
    uint256 public override totalLossesAbsorbed;

    event PrincipalRepaid(uint256 principalAmount, uint256 remainingPrincipalLent);

    error StratumTrancheVault__OnlyMarket();
    error StratumTrancheVault__InsufficientLiquidity();
    error StratumTrancheVault__ZeroAmount();
    error StratumTrancheVault__ZeroAddress();

    modifier onlyMarket() {
        if (msg.sender != market) revert StratumTrancheVault__OnlyMarket();
        _;
    }

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        TrancheTier tier_,
        uint256 targetAprBps_,
        address market_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(msg.sender) {
        if (market_ == address(0)) revert StratumTrancheVault__ZeroAddress();
        tier = tier_;
        targetAprBps = targetAprBps_;
        market = market_;
    }

    /**
     * @notice Virtual offset protecting against ERC-4626 first-depositor inflation attacks.
     *         Introduces 10^3 virtual shares.
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /**
     * @notice Total assets managed by this tranche:
     *         liquid cash held in the vault + active principal deployed in market credit lines.
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + activePrincipalLent;
    }

    /**
     * @notice Available unencumbered cash liquidity ready for borrowing or redemption.
     */
    function availableLiquidity() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Disburses underlying liquidity to a borrower originated by StratumMarket.
     * @param amount Principal liquidity amount.
     * @param recipient Destination address of funds.
     */
    function disburseLiquidity(uint256 amount, address recipient) external override onlyMarket {
        if (amount == 0) revert StratumTrancheVault__ZeroAmount();
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance < amount) revert StratumTrancheVault__InsufficientLiquidity();

        activePrincipalLent += amount;
        IERC20(asset()).safeTransfer(recipient, amount);

        emit LiquidityDisbursed(recipient, amount);
    }

    /**
     * @notice Repays active principal back into the vault from loan repayments.
     * @param principalAmount Principal amount being repaid.
     */
    function repayPrincipal(uint256 principalAmount) external onlyMarket {
        if (principalAmount == 0) return;
        if (principalAmount > activePrincipalLent) {
            activePrincipalLent = 0;
        } else {
            activePrincipalLent -= principalAmount;
        }
        emit PrincipalRepaid(principalAmount, activePrincipalLent);
    }

    /**
     * @notice Injects yield into the vault from waterfall distribution.
     * @param assetAmount Amount of yield assets transferred to vault.
     */
    function accrueYield(uint256 assetAmount) external override onlyMarket {
        emit YieldAccrued(assetAmount, totalAssets());
    }

    /**
     * @notice Writes down default/haircut loss against the active lent capital or vault equity.
     * @param lossAmount Amount of bad debt to absorb.
     * @return absorbed Actual amount absorbed by this tranche.
     */
    function absorbLoss(uint256 lossAmount) external override onlyMarket returns (uint256 absorbed) {
        if (lossAmount == 0) return 0;

        uint256 availableToAbsorb = activePrincipalLent;
        if (availableToAbsorb >= lossAmount) {
            absorbed = lossAmount;
            activePrincipalLent -= lossAmount;
        } else {
            absorbed = availableToAbsorb;
            activePrincipalLent = 0;
        }

        totalLossesAbsorbed += absorbed;
        emit LossAbsorbed(lossAmount, absorbed, totalAssets());
    }

    /**
     * @dev Restricts withdrawals/redemptions to available liquid cash in the vault.
     */
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 maxOwnerAssets = super.maxWithdraw(owner);
        uint256 cash = availableLiquidity();
        return maxOwnerAssets < cash ? maxOwnerAssets : cash;
    }

    /**
     * @dev Restricts redemptions to available liquid cash in the vault.
     */
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 maxShares = super.maxRedeem(owner);
        uint256 cash = availableLiquidity();
        uint256 sharesForCash = previewWithdraw(cash);
        return maxShares < sharesForCash ? maxShares : sharesForCash;
    }
}
