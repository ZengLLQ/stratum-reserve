// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IStratumMarket.sol";
import "../interfaces/IStratumTrancheVault.sol";
import "../interfaces/IPriceOracle.sol";
import "../libraries/StratumMath.sol";
import "../libraries/TransientLock.sol";
import "../vaults/StratumTrancheVault.sol";

/**
 * @title StratumMarket
 * @notice Central debt origination, risk management, and cascading waterfall settlement market.
 *         Governs structured credit loans funded across Senior, Mezzanine, and Junior tranches.
 */
contract StratumMarket is Ownable, TransientLock, IStratumMarket {
    using SafeERC20 for IERC20;
    using StratumMath for uint256;

    uint256 public constant SENIOR_RATIO_BPS = 7000; // 70% Senior allocation
    uint256 public constant MEZZANINE_RATIO_BPS = 2000; // 20% Mezzanine allocation
    uint256 public constant JUNIOR_RATIO_BPS = 1000; // 10% Junior allocation
    uint256 public constant BPS_DIVISOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    IERC20 public immutable override underlyingAsset;
    IPriceOracle public override oracle;
    IStratumTrancheVault public override seniorVault;
    IStratumTrancheVault public override mezzanineVault;
    IStratumTrancheVault public override juniorVault;
    address public override treasury;

    uint256 public reserveFeeBps = 500; // 5% of interest goes to protocol treasury

    // Piecewise linear interest rate parameters (in Ray, 1e27)
    uint256 public baseRateRay = 0.02e27; // 2% base APR
    uint256 public slope1Ray = 0.08e27; // 8% slope below kink
    uint256 public slope2Ray = 0.5e27; // 50% jump slope above kink
    uint256 public kinkRay = 0.8e27; // 80% utilization kink

    uint256 public nextLoanId = 1;
    uint256 public totalActivePrincipal;
    uint256 public totalReservesAccumulated;

    mapping(uint256 => Loan) public loans;
    mapping(address => CollateralConfig) public collateralConfigs;

    event ReserveFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event InterestRateParamsUpdated(uint256 baseRateRay, uint256 slope1Ray, uint256 slope2Ray, uint256 kinkRay);

    error StratumMarket__ZeroAddress();
    error StratumMarket__ZeroAmount();
    error StratumMarket__CollateralNotWhitelisted();
    error StratumMarket__ExceedsMaxLtv();
    error StratumMarket__LoanNotActive();
    error StratumMarket__LoanHealthy();
    error StratumMarket__InsufficientCollateral();
    error StratumMarket__InvalidConfig();
    error StratumMarket__DurationTooShort();

    constructor(IERC20 underlyingAsset_, IPriceOracle oracle_, address treasury_) Ownable(msg.sender) {
        if (address(underlyingAsset_) == address(0) || address(oracle_) == address(0) || treasury_ == address(0)) {
            revert StratumMarket__ZeroAddress();
        }
        underlyingAsset = underlyingAsset_;
        oracle = oracle_;
        treasury = treasury_;
    }

    /**
     * @notice Sets the three tranche vaults for this market. Can only be initialized once.
     */
    function setTranches(
        IStratumTrancheVault seniorVault_,
        IStratumTrancheVault mezzanineVault_,
        IStratumTrancheVault juniorVault_
    ) external onlyOwner {
        if (
            address(seniorVault_) == address(0) || address(mezzanineVault_) == address(0)
                || address(juniorVault_) == address(0)
        ) revert StratumMarket__ZeroAddress();

        seniorVault = seniorVault_;
        mezzanineVault = mezzanineVault_;
        juniorVault = juniorVault_;
    }

    /**
     * @notice Configures collateral asset risk parameters.
     */
    function setCollateralConfig(
        address collateralAsset,
        bool isWhitelisted,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
    ) external onlyOwner {
        if (collateralAsset == address(0)) revert StratumMarket__ZeroAddress();
        if (isWhitelisted) {
            if (ltvBps >= liquidationThresholdBps) revert StratumMarket__InvalidConfig();
            if (liquidationThresholdBps + liquidationBonusBps > BPS_DIVISOR) revert StratumMarket__InvalidConfig();
        }

        collateralConfigs[collateralAsset] = CollateralConfig({
            isWhitelisted: isWhitelisted,
            ltvBps: ltvBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps
        });

        emit CollateralConfigured(collateralAsset, isWhitelisted, ltvBps, liquidationThresholdBps, liquidationBonusBps);
    }

    function setInterestRateParams(uint256 baseRateRay_, uint256 slope1Ray_, uint256 slope2Ray_, uint256 kinkRay_)
        external
        onlyOwner
    {
        if (kinkRay_ >= 1e27) revert StratumMarket__InvalidConfig();
        baseRateRay = baseRateRay_;
        slope1Ray = slope1Ray_;
        slope2Ray = slope2Ray_;
        kinkRay = kinkRay_;
        emit InterestRateParamsUpdated(baseRateRay_, slope1Ray_, slope2Ray_, kinkRay_);
    }

    function setOracle(IPriceOracle oracle_) external onlyOwner {
        if (address(oracle_) == address(0)) revert StratumMarket__ZeroAddress();
        oracle = oracle_;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert StratumMarket__ZeroAddress();
        treasury = treasury_;
    }

    function setReserveFeeBps(uint256 bps) external onlyOwner {
        if (bps > 2000) revert StratumMarket__InvalidConfig(); // Max 20%
        emit ReserveFeeUpdated(reserveFeeBps, bps);
        reserveFeeBps = bps;
    }

    /**
     * @notice Originates a new structured credit loan secured by deposited collateral.
     */
    function borrow(address collateralAsset, uint256 collateralAmount, uint256 borrowAmount, uint256 durationSeconds)
        external
        nonReentrant
        returns (uint256 loanId)
    {
        CollateralConfig memory config = collateralConfigs[collateralAsset];
        if (!config.isWhitelisted) revert StratumMarket__CollateralNotWhitelisted();
        if (collateralAmount == 0 || borrowAmount == 0) revert StratumMarket__ZeroAmount();
        if (durationSeconds < 1 days) revert StratumMarket__DurationTooShort();

        // 1. Validate LTV constraint using oracle valuation
        (uint256 collateralPrice, uint8 colDecimals) = oracle.getAssetPrice(collateralAsset);
        (uint256 underlyingPrice, uint8 undDecimals) = oracle.getAssetPrice(address(underlyingAsset));

        uint256 collateralValueUsd = (collateralAmount * collateralPrice) / (10 ** colDecimals);
        uint256 maxBorrowUsd = (collateralValueUsd * config.ltvBps) / BPS_DIVISOR;
        uint256 borrowValueUsd = (borrowAmount * underlyingPrice) / (10 ** undDecimals);

        if (borrowValueUsd > maxBorrowUsd) revert StratumMarket__ExceedsMaxLtv();

        // 2. Partition principal across the tranche capital stack
        uint256 seniorPart = (borrowAmount * SENIOR_RATIO_BPS) / BPS_DIVISOR;
        uint256 mezzPart = (borrowAmount * MEZZANINE_RATIO_BPS) / BPS_DIVISOR;
        uint256 juniorPart = borrowAmount - seniorPart - mezzPart; // exact remainder conservation

        // 3. State update (Checks-Effects-Interactions)
        loanId = nextLoanId++;
        totalActivePrincipal += borrowAmount;
        uint256 maturity = block.timestamp + durationSeconds;

        loans[loanId] = Loan({
            id: loanId,
            borrower: msg.sender,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            principalBorrowed: borrowAmount,
            interestAccrued: 0,
            seniorPrincipal: seniorPart,
            mezzaninePrincipal: mezzPart,
            juniorPrincipal: juniorPart,
            startTimestamp: block.timestamp,
            lastAccrualTimestamp: block.timestamp,
            maturityTimestamp: maturity,
            isClosed: false,
            isDefaulted: false
        });

        emit LoanOriginated(loanId, msg.sender, collateralAsset, collateralAmount, borrowAmount, maturity);

        // 4. External interactions
        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), collateralAmount);
        seniorVault.disburseLiquidity(seniorPart, msg.sender);
        mezzanineVault.disburseLiquidity(mezzPart, msg.sender);
        juniorVault.disburseLiquidity(juniorPart, msg.sender);
    }

    /**
     * @notice Accrues continuous interest on a loan based on pool utilization.
     */
    function accrueInterest(uint256 loanId) public {
        Loan storage loan = loans[loanId];
        if (loan.isClosed || loan.isDefaulted) return;

        uint256 timeDelta = block.timestamp - loan.lastAccrualTimestamp;
        if (timeDelta == 0) return;

        // Calculate pool-wide utilization and dynamic borrow rate
        uint256 totalPoolAssets = totalActivePrincipal + seniorVault.availableLiquidity()
            + mezzanineVault.availableLiquidity() + juniorVault.availableLiquidity();

        uint256 borrowRateRay = StratumMath.calculateBorrowRate(
            totalActivePrincipal, totalPoolAssets, baseRateRay, slope1Ray, slope2Ray, kinkRay
        );

        // Compounded interest delta
        uint256 currentTotalDebt = loan.principalBorrowed + loan.interestAccrued;
        uint256 interestDelta = (currentTotalDebt * (borrowRateRay / 1e9) * timeDelta) / (SECONDS_PER_YEAR * 1e18);

        loan.interestAccrued += interestDelta;
        loan.lastAccrualTimestamp = block.timestamp;

        emit InterestAccrued(loanId, interestDelta, loan.interestAccrued);
    }

    /**
     * @notice Repays principal and accrued interest on a loan through cascading waterfall settlement.
     */
    function repay(uint256 loanId, uint256 amount) external nonReentrant {
        if (amount == 0) revert StratumMarket__ZeroAmount();
        _repayInternal(loanId, amount, msg.sender);
    }

    function _repayInternal(uint256 loanId, uint256 amount, address payer) internal {
        Loan storage loan = loans[loanId];
        if (loan.isClosed || loan.isDefaulted) revert StratumMarket__LoanNotActive();

        accrueInterest(loanId);

        uint256 totalDebt = loan.principalBorrowed + loan.interestAccrued;
        uint256 amountToPay = amount > totalDebt ? totalDebt : amount;

        // Pull repayment from payer
        underlyingAsset.safeTransferFrom(payer, address(this), amountToPay);

        uint256 interestPaid = 0;
        uint256 principalPaid = 0;

        if (amountToPay <= loan.interestAccrued) {
            interestPaid = amountToPay;
            loan.interestAccrued -= interestPaid;
        } else {
            interestPaid = loan.interestAccrued;
            principalPaid = amountToPay - interestPaid;
            loan.interestAccrued = 0;
            loan.principalBorrowed -= principalPaid;
        }

        // 1. Cascading Interest Waterfall
        if (interestPaid > 0) {
            _distributeInterestWaterfall(loanId, interestPaid);
        }

        // 2. Cascading Principal Waterfall
        if (principalPaid > 0) {
            _distributePrincipalWaterfall(loanId, principalPaid);
        }

        uint256 remainingDebt = loan.principalBorrowed + loan.interestAccrued;
        emit LoanRepaid(loanId, payer, amountToPay, principalPaid, interestPaid, remainingDebt);

        // 3. If loan is fully settled, release collateral back to borrower
        if (remainingDebt == 0) {
            loan.isClosed = true;
            uint256 refundCollateral = loan.collateralAmount;
            loan.collateralAmount = 0;
            if (refundCollateral > 0) {
                IERC20(loan.collateralAsset).safeTransfer(loan.borrower, refundCollateral);
            }
        }
    }

    /**
     * @dev Executes cascading priority waterfall for interest cash flows.
     */
    function _distributeInterestWaterfall(uint256 loanId, uint256 interestPaid) internal {
        Loan storage loan = loans[loanId];

        // Step 1: Protocol Treasury Reserve Fee
        uint256 treasuryFee = (interestPaid * reserveFeeBps) / BPS_DIVISOR;
        if (treasuryFee > 0) {
            totalReservesAccumulated += treasuryFee;
            underlyingAsset.safeTransfer(treasury, treasuryFee);
        }

        uint256 netInterest = interestPaid - treasuryFee;
        uint256 timeElapsed = block.timestamp - loan.startTimestamp;
        if (timeElapsed == 0) timeElapsed = 1;

        // Step 2: Senior Tranche Target Yield (First Priority)
        uint256 seniorTargetYield =
            (loan.seniorPrincipal * seniorVault.targetAprBps() * timeElapsed) / (SECONDS_PER_YEAR * BPS_DIVISOR);
        uint256 seniorYield = netInterest < seniorTargetYield ? netInterest : seniorTargetYield;
        uint256 remainingAfterSenior = netInterest - seniorYield;

        // Step 3: Mezzanine Tranche Target Yield (Second Priority)
        uint256 mezzTargetYield =
            (loan.mezzaninePrincipal * mezzanineVault.targetAprBps() * timeElapsed) / (SECONDS_PER_YEAR * BPS_DIVISOR);
        uint256 mezzYield = remainingAfterSenior < mezzTargetYield ? remainingAfterSenior : mezzTargetYield;

        // Step 4: Junior Tranche Residual Yield (Captures All Excess Upside)
        uint256 juniorYield = remainingAfterSenior - mezzYield;

        emit WaterfallDistributed(loanId, treasuryFee, seniorYield, mezzYield, juniorYield);

        // Transfer yield assets to respective vaults
        if (seniorYield > 0) {
            underlyingAsset.safeTransfer(address(seniorVault), seniorYield);
            seniorVault.accrueYield(seniorYield);
        }
        if (mezzYield > 0) {
            underlyingAsset.safeTransfer(address(mezzanineVault), mezzYield);
            mezzanineVault.accrueYield(mezzYield);
        }
        if (juniorYield > 0) {
            underlyingAsset.safeTransfer(address(juniorVault), juniorYield);
            juniorVault.accrueYield(juniorYield);
        }
    }

    /**
     * @dev Executes principal redemption waterfall across tranches.
     */
    function _distributePrincipalWaterfall(uint256 loanId, uint256 principalPaid) internal {
        Loan storage loan = loans[loanId];
        uint256 totalOrigPrincipal = loan.seniorPrincipal + loan.mezzaninePrincipal + loan.juniorPrincipal;
        if (totalOrigPrincipal == 0) return;

        uint256 seniorRepaid = (principalPaid * loan.seniorPrincipal) / totalOrigPrincipal;
        uint256 mezzRepaid = (principalPaid * loan.mezzaninePrincipal) / totalOrigPrincipal;
        uint256 juniorRepaid = principalPaid - seniorRepaid - mezzRepaid; // exact remainder conservation

        // State updates before external calls
        loan.seniorPrincipal -= seniorRepaid;
        loan.mezzaninePrincipal -= mezzRepaid;
        loan.juniorPrincipal -= juniorRepaid;
        totalActivePrincipal -= principalPaid;

        if (seniorRepaid > 0) {
            underlyingAsset.safeTransfer(address(seniorVault), seniorRepaid);
            StratumTrancheVault(payable(address(seniorVault))).repayPrincipal(seniorRepaid);
        }
        if (mezzRepaid > 0) {
            underlyingAsset.safeTransfer(address(mezzanineVault), mezzRepaid);
            StratumTrancheVault(payable(address(mezzanineVault))).repayPrincipal(mezzRepaid);
        }
        if (juniorRepaid > 0) {
            underlyingAsset.safeTransfer(address(juniorVault), juniorRepaid);
            StratumTrancheVault(payable(address(juniorVault))).repayPrincipal(juniorRepaid);
        }
    }

    /**
     * @notice Liquidates an unhealthy or expired loan with discounted collateral liquidation bonus.
     */
    function liquidateLoan(uint256 loanId, uint256 debtToRepay) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.isClosed || loan.isDefaulted) revert StratumMarket__LoanNotActive();
        if (debtToRepay == 0) revert StratumMarket__ZeroAmount();

        accrueInterest(loanId);

        uint256 healthFactor = getLoanHealthFactor(loanId);
        bool isExpired = block.timestamp > loan.maturityTimestamp;

        if (healthFactor >= 1e18 && !isExpired) {
            revert StratumMarket__LoanHealthy();
        }

        uint256 totalDebt = loan.principalBorrowed + loan.interestAccrued;
        uint256 actualDebtRepay = debtToRepay > totalDebt ? totalDebt : debtToRepay;

        CollateralConfig memory config = collateralConfigs[loan.collateralAsset];

        // Calculate seized collateral with liquidation bonus
        (uint256 colPrice, uint8 colDecimals) = oracle.getAssetPrice(loan.collateralAsset);
        (uint256 undPrice, uint8 undDecimals) = oracle.getAssetPrice(address(underlyingAsset));

        uint256 repayValueUsd = (actualDebtRepay * undPrice) / (10 ** undDecimals);
        uint256 bonusFactor = BPS_DIVISOR + config.liquidationBonusBps;
        uint256 collateralValueToSeizeUsd = (repayValueUsd * bonusFactor) / BPS_DIVISOR;

        uint256 collateralToSeize = (collateralValueToSeizeUsd * (10 ** colDecimals)) / colPrice;
        if (collateralToSeize > loan.collateralAmount) {
            collateralToSeize = loan.collateralAmount;
            // Cap debt repay based on available collateral
            uint256 actualColValUsd = (collateralToSeize * colPrice) / (10 ** colDecimals);
            actualDebtRepay = (actualColValUsd * BPS_DIVISOR * (10 ** undDecimals)) / (bonusFactor * undPrice);
        }

        loan.collateralAmount -= collateralToSeize;

        emit LoanLiquidated(loanId, msg.sender, actualDebtRepay, collateralToSeize, loan.collateralAmount);

        // Transfer seized collateral to liquidator
        IERC20(loan.collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        // Execute internal debt repayment with waterfall
        if (actualDebtRepay > 0) {
            _repayInternal(loanId, actualDebtRepay, msg.sender);
        }

        // If all collateral is exhausted and debt remains, write off bad debt immediately
        uint256 remainingDebt = loan.principalBorrowed + loan.interestAccrued;
        if (loan.collateralAmount == 0 && remainingDebt > 0) {
            _writeOffBadDebt(loanId, remainingDebt);
        }
    }

    /**
     * @dev Reverse loss waterfall: Junior absorbs first -> Mezzanine absorbs second -> Senior absorbs last.
     */
    function _writeOffBadDebt(uint256 loanId, uint256 badDebt) internal {
        Loan storage loan = loans[loanId];
        loan.isDefaulted = true;
        loan.isClosed = true;

        totalActivePrincipal -= loan.principalBorrowed;
        loan.principalBorrowed = 0;
        loan.interestAccrued = 0;

        // Step 1: Junior tranche absorbs loss first (First-Loss Protection)
        uint256 juniorAbsorbed = juniorVault.absorbLoss(badDebt);
        uint256 remainingBadDebt = badDebt - juniorAbsorbed;

        // Step 2: Mezzanine tranche absorbs subsequent loss
        uint256 mezzAbsorbed = 0;
        if (remainingBadDebt > 0) {
            mezzAbsorbed = mezzanineVault.absorbLoss(remainingBadDebt);
            remainingBadDebt -= mezzAbsorbed;
        }

        // Step 3: Senior tranche absorbs only if subordinate tranches are exhausted
        uint256 seniorAbsorbed = 0;
        if (remainingBadDebt > 0) {
            seniorAbsorbed = seniorVault.absorbLoss(remainingBadDebt);
        }

        emit BadDebtWrittenOff(loanId, badDebt, juniorAbsorbed, mezzAbsorbed, seniorAbsorbed);
    }

    /**
     * @notice Computes current health factor of a loan.
     */
    function getLoanHealthFactor(uint256 loanId) public view override returns (uint256 healthFactor) {
        Loan memory loan = loans[loanId];
        if (loan.isClosed) return type(uint256).max;

        uint256 totalDebt = loan.principalBorrowed + loan.interestAccrued;
        if (totalDebt == 0) return type(uint256).max;

        (uint256 colPrice, uint8 colDecimals) = oracle.getAssetPrice(loan.collateralAsset);
        (uint256 undPrice, uint8 undDecimals) = oracle.getAssetPrice(address(underlyingAsset));

        uint256 collateralValueUsd = (loan.collateralAmount * colPrice) / (10 ** colDecimals);
        uint256 totalDebtUsd = (totalDebt * undPrice) / (10 ** undDecimals);

        CollateralConfig memory config = collateralConfigs[loan.collateralAsset];
        return StratumMath.calculateHealthFactor(collateralValueUsd, totalDebtUsd, config.liquidationThresholdBps);
    }

    function getLoan(uint256 loanId) external view override returns (Loan memory) {
        return loans[loanId];
    }

    function getLoanTotalDebt(uint256 loanId) external view override returns (uint256 totalDebt) {
        Loan memory loan = loans[loanId];
        return loan.principalBorrowed + loan.interestAccrued;
    }
}
