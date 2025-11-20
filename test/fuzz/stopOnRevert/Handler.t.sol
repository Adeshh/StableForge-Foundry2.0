//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    uint256 public timesMinted;
    uint256 public timesDeposited;
    uint256 public timesRedeemed;
    uint256 public timesDepositedAndMinted;

    // Track addresses that have deposited collateral
    mapping(address => bool) public hasDeposited;

    // Constants
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public immutable LIQUIDATION_THRESHOLD;
    uint256 public immutable LIQUIDATION_PRECISION;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        LIQUIDATION_THRESHOLD = dsce.getLiquidationThreshold();
        LIQUIDATION_PRECISION = dsce.getLiquidationPrecision();
        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // Mint tokens to msg.sender (which will be a random address from targetSenders)
        collateral.mint(msg.sender, amount);

        vm.startPrank(msg.sender);
        // Approve the DSCEngine to spend tokens
        collateral.approve(address(dsce), amount);

        // Deposit collateral
        dsce.depositCollateral(address(collateral), amount);
        vm.stopPrank();

        // Mark this address as having deposited
        hasDeposited[msg.sender] = true;
        timesDeposited++;
    }

    function depositCollateralAndMintDSC(uint256 collateralSeed, uint256 collateralAmount, uint256 dscAmountToMint)
        public
    {
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // Mint tokens to msg.sender (which will be a random address from targetSenders)
        collateral.mint(msg.sender, collateralAmount);

        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(msg.sender);
        uint256 depositingCollateralValueInUsd = dsce.getUsdValue(address(collateral), collateralAmount);

        // After depositing: total collateral = totalCollateralValueInUsd + depositingCollateralValueInUsd
        // Max total DSC allowed = (totalCollateralValueInUsd + depositingCollateralValueInUsd) / overcollatralization ratio
        // Max additional DSC to mint = max total DSC - current DSC minted
        uint256 totalCollateralAfterDeposit = totalCollateralValueInUsd + depositingCollateralValueInUsd;
        uint256 maxTotalDscAllowed = totalCollateralAfterDeposit / (LIQUIDATION_PRECISION / LIQUIDATION_THRESHOLD);

        // Check if we can mint any additional DSC (avoid underflow)
        if (totalDscMinted >= maxTotalDscAllowed) {
            // Can't mint more, already at or over the limit
            return;
        }

        uint256 maxDscToMint = maxTotalDscAllowed - totalDscMinted;

        // Bound the dscAmountToMint
        dscAmountToMint = bound(dscAmountToMint, 0, maxDscToMint);

        // If bound result is 0, return early
        if (dscAmountToMint == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        // Approve the DSCEngine to spend tokens
        collateral.approve(address(dsce), collateralAmount);

        // Deposit collateral and mint DSC
        dsce.depositCollateralAndMintDSC(address(collateral), collateralAmount, dscAmountToMint);
        vm.stopPrank();

        // Mark this address as having deposited
        hasDeposited[msg.sender] = true;
        timesDepositedAndMinted++;
    }

    function mintDSC(uint256 dscAmountToMint) public {
        // Only allow minting if this address has deposited collateral
        if (!hasDeposited[msg.sender]) {
            return;
        }

        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(msg.sender);
        uint256 maxDscToMint =
            (totalCollateralValueInUsd / (LIQUIDATION_PRECISION / LIQUIDATION_THRESHOLD)) - totalDscMinted;

        if (maxDscToMint < 0) {
            return;
        }
        dscAmountToMint = bound(dscAmountToMint, 0, uint256(maxDscToMint));
        if (dscAmountToMint == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        dsce.mintDSC(dscAmountToMint);
        vm.stopPrank();
        timesMinted++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amount) public {
        // Only allow redeeming if this address has deposited collateral
        if (!hasDeposited[msg.sender]) {
            return;
        }

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // Get the amount deposited by user for this specific collateral token
        uint256 deposited = dsce.getCollateralDeposited(msg.sender, address(collateral));

        // Only redeem if we have collateral deposited for this specific token
        if (deposited == 0) {
            return;
        }

        // Get account information to check health factor
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(msg.sender);

        // Calculate max USD value we can redeem while maintaining 2x overcollateralization
        // Formula: (totalCollateralValueInUsd - amountToRedeemUsd) >= (totalDscMinted * 2)
        // Therefore: amountToRedeemUsd <= totalCollateralValueInUsd - (totalDscMinted * 2)

        // Check if we can redeem anything (avoid underflow)
        if (totalDscMinted * (LIQUIDATION_PRECISION / LIQUIDATION_THRESHOLD) >= totalCollateralValueInUsd) {
            return; // Can't redeem anything, already at minimum collateralization
        }

        uint256 maxAmountToRedeemInUsd =
            totalCollateralValueInUsd - (totalDscMinted * (LIQUIDATION_PRECISION / LIQUIDATION_THRESHOLD));

        // Get USD value of this specific token deposited
        uint256 depositedUsdValue = dsce.getUsdValue(address(collateral), deposited);

        // Can't redeem more than what we have of this token OR more than the max allowed
        // Take the minimum
        if (maxAmountToRedeemInUsd > depositedUsdValue) {
            maxAmountToRedeemInUsd = depositedUsdValue;
        }

        // Convert USD value back to token amount
        uint256 maxAmountToRedeem = dsce.getTokenAmountFromUsd(address(collateral), maxAmountToRedeemInUsd);

        // Ensure we don't try to redeem more than deposited (safety check)
        if (maxAmountToRedeem > deposited) {
            maxAmountToRedeem = deposited;
        }

        // Can't redeem if maxAmountToRedeem is 0
        if (maxAmountToRedeem == 0) {
            return;
        }

        // Bound the amount to what we can safely redeem
        amount = bound(amount, 1, maxAmountToRedeem);

        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amount);
        vm.stopPrank();

        timesRedeemed++;
    }

    //Below Function Breaks the Invariant Test/Known Issue
    // function updateCollateralPrice(uint256 collateralSeed, uint96 newPrice) public {
    //    int256 newPriceInt = int256(uint256(newPrice));
    //    if (collateralSeed % 2 == 0) {
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    //    } else {
    //     btcUsdPriceFeed.updateAnswer(newPriceInt);
    //    }
    // }

    ////Helper Functions////
    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
