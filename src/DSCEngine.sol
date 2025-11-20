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
import {OracleLib} from "./libraries/OracleLib.sol";
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
    error DSCEngine__HealthFactorOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    // State Variables   //
    ///////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //Means 2x overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10%

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////////
    // Events           //
    //////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
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
    function depositCollateralAndMintDSC(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 dscAmountToMint
    ) external {
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
    function redeemCollateralForDSC(address collateralTokenToRedeem, uint256 amountToRedeem, uint256 dscAmountToBurn)
        external
    {
        _burnDsc(dscAmountToBurn, msg.sender, msg.sender);
        _redeemCollateral(collateralTokenToRedeem, amountToRedeem, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateralTokenToRedeem - The address of the collateral token to redeem
     * @param amountToRedeem - The amount of collateral to redeem
     * @notice The function will revert if the health factor is not above 1 after the redemption of collateral.
     */
    function redeemCollateral(address collateralTokenToRedeem, uint256 amountToRedeem)
        external
        nonReentrant
        moreThanZero(amountToRedeem)
        isAllowedToken(collateralTokenToRedeem)
    {
        _redeemCollateral(collateralTokenToRedeem, amountToRedeem, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amount - The amount of DSC to mint
     * @notice The amount of DSC to mint is based on the amount of collateral deposited and the price feed of the collateral and depositedCollateralValue > desiredDscAmount
     */
    function mintDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_DscMinted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) external moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
    }

    /**
     * @param collateralToken - The address of the collateral token
     * @param userToLiquidate - The address of the user to liquidate
     * @param debtToCover - The amount of debt to cover
     * @notice In order to liquidate a user, the health factor of the user must be less than 1.
     *         The liquidator will receive a bonus(extra collateral) for the debt that is covered.
     *         You can partially liquidate a user.
     *         The system assumes that the protocol will be always overcollatralized (100% or more), so that the liquidator will receive a bonus for the debt that is covered.
     */
    function liquidate(address collateralToken, address userToLiquidate, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        isAllowedToken(collateralToken)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(userToLiquidate);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk(startingUserHealthFactor);
        }
        //
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralToken, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateralToken, totalCollateralToRedeem, userToLiquidate, msg.sender);
        _burnDsc(debtToCover, userToLiquidate, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(userToLiquidate);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender); //Dont think liquidator paying dsc on behalf of user is going to  reduce liquidator health factor. but just in case.
    }

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
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(healthFactor);
        }
    }

    function _redeemCollateral(address collateralTokenToRedeem, uint256 amountToRedeem, address from, address to)
        private
    {
        s_collateralDeposited[from][collateralTokenToRedeem] -= amountToRedeem;
        emit CollateralRedeemed(from, to, collateralTokenToRedeem, amountToRedeem);
        bool success = IERC20(collateralTokenToRedeem).transfer(to, amountToRedeem);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev this is low level internal function to burn DSC. It is used to burn DSC on behalf of a user.
     * @param amountToBurn - The amount of DSC to burn
     * @param onBehalfOf - The address of the user to burn the DSC on behalf of
     * @param dscFrom - the address which is sending the DSC to be burned
     */
    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
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
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * amount * ADDITIONAL_FEED_PRECISION)) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
        public
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getDsc() public view returns (address) {
        return address(i_dsc);
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() public pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() public pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() public pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralDeposited(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMinted(address user) public view returns (uint256) {
        return s_DscMinted[user];
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }
}
