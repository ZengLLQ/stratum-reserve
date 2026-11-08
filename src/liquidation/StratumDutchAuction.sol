// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IStratumMarket.sol";
import "../libraries/TransientLock.sol";

/**
 * @title StratumDutchAuction
 * @notice Dutch auction liquidation engine for orderly liquidation of distressed collateral
 *         without sudden price impact or flash-loan front-running manipulation.
 */
contract StratumDutchAuction is Ownable, TransientLock {
    using SafeERC20 for IERC20;

    struct Auction {
        uint256 id;
        uint256 loanId;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 debtToCover;
        uint256 startPriceUsd; // in 18 decimals USD
        uint256 floorPriceUsd; // in 18 decimals USD
        uint256 startTime;
        uint256 duration; // in seconds
        bool isSettled;
    }

    IStratumMarket public immutable market;
    IERC20 public immutable underlyingAsset;

    uint256 public nextAuctionId = 1;
    mapping(uint256 => Auction) public auctions;

    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 indexed loanId,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtToCover,
        uint256 startPriceUsd,
        uint256 floorPriceUsd,
        uint256 duration
    );

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed buyer,
        uint256 collateralBought,
        uint256 costUnderlying,
        uint256 executionPriceUsd
    );

    error StratumDutchAuction__ZeroAddress();
    error StratumDutchAuction__ZeroAmount();
    error StratumDutchAuction__AuctionNotActive();
    error StratumDutchAuction__InvalidPriceBounds();
    error StratumDutchAuction__LoanNotLiquidatable();

    constructor(address market_, address underlyingAsset_) Ownable(msg.sender) {
        if (market_ == address(0) || underlyingAsset_ == address(0)) {
            revert StratumDutchAuction__ZeroAddress();
        }
        market = IStratumMarket(market_);
        underlyingAsset = IERC20(underlyingAsset_);
    }

    /**
     * @notice Initiates a Dutch auction for an undercollateralized or expired loan.
     * @param loanId The loan to auction.
     * @param startPriceUsd Starting price per unit of collateral (18 decimals USD).
     * @param floorPriceUsd Reserve floor price per unit of collateral (18 decimals USD).
     * @param duration Duration over which price decays linearly (e.g. 1800 to 7200 seconds).
     */
    function startAuction(uint256 loanId, uint256 startPriceUsd, uint256 floorPriceUsd, uint256 duration)
        external
        nonReentrant
        returns (uint256 auctionId)
    {
        if (floorPriceUsd >= startPriceUsd || floorPriceUsd == 0) {
            revert StratumDutchAuction__InvalidPriceBounds();
        }
        if (duration < 300) revert StratumDutchAuction__ZeroAmount();

        IStratumMarket.Loan memory loan = market.getLoan(loanId);
        if (loan.isClosed || loan.isDefaulted) revert StratumDutchAuction__AuctionNotActive();

        uint256 healthFactor = market.getLoanHealthFactor(loanId);
        bool isExpired = block.timestamp > loan.maturityTimestamp;
        if (healthFactor >= 1e18 && !isExpired) {
            revert StratumDutchAuction__LoanNotLiquidatable();
        }

        uint256 totalDebt = loan.principalBorrowed + loan.interestAccrued;
        if (totalDebt == 0 || loan.collateralAmount == 0) revert StratumDutchAuction__ZeroAmount();

        auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            id: auctionId,
            loanId: loanId,
            collateralAsset: loan.collateralAsset,
            collateralAmount: loan.collateralAmount,
            debtToCover: totalDebt,
            startPriceUsd: startPriceUsd,
            floorPriceUsd: floorPriceUsd,
            startTime: block.timestamp,
            duration: duration,
            isSettled: false
        });

        emit AuctionStarted(
            auctionId,
            loanId,
            loan.collateralAsset,
            loan.collateralAmount,
            totalDebt,
            startPriceUsd,
            floorPriceUsd,
            duration
        );
    }

    /**
     * @notice Computes current decaying auction price per unit of collateral.
     * @param auctionId The ID of the auction.
     * @return currentPrice Current price in 18 decimals USD.
     */
    function getCurrentPrice(uint256 auctionId) public view returns (uint256 currentPrice) {
        Auction memory auction = auctions[auctionId];
        if (auction.isSettled) return 0;

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed >= auction.duration) {
            return auction.floorPriceUsd;
        }

        uint256 priceDrop = auction.startPriceUsd - auction.floorPriceUsd;
        uint256 decay = (priceDrop * elapsed) / auction.duration;
        return auction.startPriceUsd - decay;
    }

    /**
     * @notice Purchases collateral from the Dutch auction and settles debt directly with the market.
     * @param auctionId The ID of the auction.
     */
    function buyCollateral(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (auction.isSettled) revert StratumDutchAuction__AuctionNotActive();

        auction.isSettled = true;
        uint256 execPrice = getCurrentPrice(auctionId);

        // Accrue interest up to the current block timestamp so debt calculation is exact
        market.accrueInterest(auction.loanId);
        uint256 totalDebt = market.getLoanTotalDebt(auction.loanId);
        if (totalDebt == 0) revert StratumDutchAuction__ZeroAmount();

        // Transfer underlying payment from buyer to market and repay loan
        underlyingAsset.safeTransferFrom(msg.sender, address(this), totalDebt);
        underlyingAsset.forceApprove(address(market), totalDebt);
        market.liquidateLoan(auction.loanId, totalDebt);

        emit AuctionSettled(auctionId, msg.sender, auction.collateralAmount, totalDebt, execPrice);
    }
}
