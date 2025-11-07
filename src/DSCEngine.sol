// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title  - DSCEngine
 * @author - @Adeshh
 * @notice - All the functions in this contract follow the Checks-Effects-Interactions pattern.
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always  be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////////
    // Errors           //
    //////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__InvalidCollateralToken();
    error DSCEngine__InvalidPriceFeedsOrCollateralTokens();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    ///////////////////////
    // State Variables   //
    ///////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //Means 2x overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////////
    // Events           //
    //////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);
    ///////////////////////
    // Modifiers        //
    //////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__InvalidCollateralToken();
        }
        _;
    }

    ///////////////////////
    // Functions        ///
    ///////////////////////
    constructor(address[] memory collateralTokens, address[] memory priceFeeds, address dscAddress) {
        if (collateralTokens.length != priceFeeds.length) {
            revert DSCEngine__InvalidPriceFeedsOrCollateralTokens();
        }
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            s_priceFeeds[collateralTokens[i]] = priceFeeds[i];
            s_collateralTokens.push(collateralTokens[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////
    // External Functions//
    ///////////////////////
    /**
     * @notice - This function is used to deposit collateral and mint DSC in a single transaction.
     * @param collateralTokenAddress - The address of the collateral token to deposit
     * @param collateralAmount - The amount of collateral to deposit
     * @param dscAmountToMint - The amount of DSC to mint
     */
    function depositCollateralAndMintDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmountToMint) external {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDSC(dscAmountToMint);
    }

    /**
     * @param collateralTokenAddress - The address of the collateral token to deposit
     * @param collateralAmount - The amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param collateralTokenToRedeem - The address of the collateral token to redeem
     * @param amountToRedeem - The amount of collateral to redeem
     * @param dscAmountToBurn - The amount of DSC to burn
     * @notice This function burns DSC and then redeems collateral in a single transaction.
     *         Since the function redeemCollateral already if health factor is broken, we don't need to check it again.
     */
    function redeemCollateralForDSC(address collateralTokenToRedeem, uint256 amountToRedeem, uint256 dscAmountToBurn) external {
        burnDsc(dscAmountToBurn);
        redeemCollateral(collateralTokenToRedeem, amountToRedeem);
    }

    /**
     * @param collateralTokenToRedeem - The address of the collateral token to redeem
     * @param amountToRedeem - The amount of collateral to redeem
     * @notice The function will revert if the health factor is not above 1 after the redemption of collateral.
     */
    function redeemCollateral(address collateralTokenToRedeem, uint256 amountToRedeem) public nonReentrant moreThanZero(amountToRedeem) {
        s_collateralDeposited[msg.sender][collateralTokenToRedeem] -= amountToRedeem;
        emit CollateralRedeemed(msg.sender, collateralTokenToRedeem, amountToRedeem);
        bool success = IERC20(collateralTokenToRedeem).transfer(msg.sender, amountToRedeem);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthIsBroken(msg.sender);
    }

    /**
     * @param amount - The amount of DSC to mint
     * @notice The amount of DSC to mint is based on the amount of collateral deposited and the price feed of the collateral and depositedCollateralValue > desiredDscAmount
     */
    function mintDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_DscMinted[msg.sender] += amount;
        revertIfHealthIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn){
        s_DscMinted[msg.sender] -= amountToBurn;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal view Functions //
    ///////////////////////////////////////
    /**
     * @param user - The address of the user to check the account information of
     * @return totalDscMinted - The total amount of DSC minted by the user
     * @return totalCollateralValueInUsd - The total value of the collateral deposited by the user in USD
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        totalCollateralValueInUsd = getAccountTotalCollateralValue(user);
    }

    /**
     * @param user - The address of the user to check the health factor of
     * @return The health factor of the user
     * @notice The health factor is the ratio of the value of all collateral deposited to the value of the DSC minted.
     *         If the health factor is less than 1, the user is undercollateralized and could be liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; //This will return a value greater than 1 if the user is healthy.
    }

    function revertIfHealthIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(healthFactor);
        }
    }

    //////////////////////////////////////
    // Public & External view Functions //
    //////////////////////////////////////
    /**
     * @param user - The address of the user to check the collateral value of
     * @return totalCollateralValueInUsd - The total value of the collateral deposited by the user in USD
     * @notice - This function is used to get the total value of the collateral deposited by the user in USD by looping through all
     *           the collateral tokens and then mapping it to the price feed.
     */
    function getAccountTotalCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    /**
     * @param token - The address of the token to get the USD value of
     * @param amount - The amount of the token to get the USD value of
     * @return The USD value of the token
     * @notice - This function is used to get the USD value of a token by multiplying the price by the amount and then dividing by the precision.
     *         - Multiplying by ADDITIONAL_FEED_PRECISION to convert the price to 18 decimals as the price feed is in 8 decimals.
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * amount * ADDITIONAL_FEED_PRECISION)) / PRECISION;
    }
}
