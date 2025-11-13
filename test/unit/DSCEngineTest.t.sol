//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address wbtc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    uint256 deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant INITIAL_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, INITIAL_USER_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, INITIAL_USER_BALANCE);
    }

    modifier fundLiquidator() {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();
        _;
    }

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();
        _;
    }

    /////////////////////////////
    ///Constructor Tests      ///
    /////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthAndPriceFeedsLengthAreMismatched() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__InvalidPriceFeedsOrCollateralTokens.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testIfConstructorSetsTokenAndPriceFeedsCorrectly() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens.length, 2);

        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);

        assertEq(dsce.getCollateralTokenPriceFeed(weth), wethUsdPriceFeed);
        assertEq(dsce.getCollateralTokenPriceFeed(wbtc), wbtcUsdPriceFeed);
    }

    /////////////////////////////
    ///Price Tests            ///
    /////////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wethUsdPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 expectedUsd = uint256(ethAmount) * uint256(price) / 1e8;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    function testGetAccountTotalCollateralValue() public collateralDeposited {
        uint256 totalCollateralValueInUsd = dsce.getAccountTotalCollateralValue(USER);
        uint256 expectedTotalCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalCollateralValueInUsd, expectedTotalCollateralValueInUsd);
    }

    //////////////////////////////
    ///DepositCollateral Tests ///
    //////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfCollateralIsNotAllowed() public {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__InvalidCollateralToken.selector);
        dsce.depositCollateral(address(dsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInformation() public collateralDeposited {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dsce.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd);
    }

    function testEmitCollateralDepositedWithCorrectParameters() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////////////
    ///DepositCollateralAndMintDsc Tests ///
    ////////////////////////////////////////
    function testCanDepositeCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDscMinted = 100 ether;
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(totalCollateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testRevertIfMintedDscExceedsCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert();
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100000000000 ether);
        vm.stopPrank();
    }

    //////////////////////////////
    ///RedeemCollareral Tests  ///
    //////////////////////////////
    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfCollateralIsNotAllowed() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__InvalidCollateralToken.selector);
        dsce.redeemCollateral(address(dsc), 1 ether);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositCollateralAndMintedDsc {
        uint256 collateralToRedeem = 1 ether;
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBrokenWhileRedeeming() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfTryingToRedeemMoreCollateralThanUserHas()
        public
        depositCollateralAndMintedDsc
    {
        uint256 collateralToRedeem = 101 ether;
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();
    }

    function testRedeemingUpdatesStateAndHealthFactor() public depositCollateralAndMintedDsc {
        uint256 collateralToRedeem = 1 ether;
        uint256 startingHealthFactor = dsce.getHealthFactor(USER);
        uint256 startingCollateralAmount = dsce.getCollateralDeposited(USER, weth);
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();
        uint256 endingCollateralAmount = dsce.getCollateralDeposited(USER, weth);
        uint256 endingHealthFactor = dsce.getHealthFactor(USER);
        assertEq(endingCollateralAmount, (startingCollateralAmount - collateralToRedeem));
        assert(startingHealthFactor > endingHealthFactor);
    }

    function testCanRedeemCollateralForDsc() public depositCollateralAndMintedDsc {
        uint256 dscAmountToRedeem = 10 ether;
        uint256 collateralToRedeem = 1 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToRedeem);
        dsce.redeemCollateralForDSC(weth, collateralToRedeem, dscAmountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralForDscUpdatesStateAndHealthFactor() public depositCollateralAndMintedDsc {
        uint256 dscAmountToRedeem = 10 ether;
        uint256 collateralToRedeem = 2 ether;
        uint256 startingHealthFactor = dsce.getHealthFactor(USER);
        uint256 startingCollateralAmount = dsce.getCollateralDeposited(USER, weth);
        uint256 startingDscAmount = dsce.getDscMinted(USER);
        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToRedeem);
        dsce.redeemCollateralForDSC(weth, collateralToRedeem, dscAmountToRedeem);
        vm.stopPrank();

        uint256 endingCollateralAmount = dsce.getCollateralDeposited(USER, weth);
        uint256 endingDscAmount = dsce.getDscMinted(USER);
        uint256 endingHealthFactor = dsce.getHealthFactor(USER);
        assertEq(endingCollateralAmount, (startingCollateralAmount - collateralToRedeem));
        assertEq(endingDscAmount, (startingDscAmount - dscAmountToRedeem));
        assert(startingHealthFactor != endingHealthFactor);
    }

    function testRevertsIfTryingToRedeemMoreDscThanUserHas() public depositCollateralAndMintedDsc {
        uint256 dscAmountToRedeem = 101 ether;
        uint256 collateralToRedeem = 1 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToRedeem);
        vm.expectRevert();
        dsce.redeemCollateralForDSC(weth, collateralToRedeem, dscAmountToRedeem);
        vm.stopPrank();
    }

    function testRevertsIfTryingToRedeemMoreCollateralThanUserHas() public depositCollateralAndMintedDsc {
        uint256 dscAmountToRedeem = 10 ether;
        uint256 collateralToRedeem = 101 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToRedeem);
        vm.expectRevert();
        dsce.redeemCollateralForDSC(weth, collateralToRedeem, dscAmountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralForDscFailsIfItWouldBreakHealthFactor() public depositCollateralAndMintedDsc {
       uint256 ethAmountToRedeem = 10 ether;
       uint256 amountThatWouldBeLeftAfterRedeem =  AMOUNT_COLLATERAL - ethAmountToRedeem;
       uint256 dscAmountToRedeem = 1 ether;
       uint256 dscAmountThatWouldBeLeftAfterRedeem = 9 ether;
       uint256 expectedHealthFactor = dsce.calculateHealthFactor(dscAmountThatWouldBeLeftAfterRedeem, dsce.getUsdValue(weth, amountThatWouldBeLeftAfterRedeem));

       vm.startPrank(USER);
       dsc.approve(address(dsce), ethAmountToRedeem);
       vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBroken.selector, expectedHealthFactor));
       dsce.redeemCollateralForDSC(weth, ethAmountToRedeem, dscAmountToRedeem);
       vm.stopPrank();
       
    }

    function testEmitCollateralRedeemedWithCorrectParameters() public depositCollateralAndMintedDsc {
        uint256 amountToRedeem = 1 ether;

        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, amountToRedeem);

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    //////////////////////////////
    ///MintDsc Tests           ///
    //////////////////////////////
    function testCanMintDsc() public collateralDeposited {
        uint256 dscAmountToMint = 100 ether;
        vm.startPrank(USER);
        dsce.mintDSC(dscAmountToMint);
        vm.stopPrank();
    }

    function testMintDscRevertsIfItWouldBreakHealthFactor() public collateralDeposited {
       (, int256 price,,,) = AggregatorV3Interface(wethUsdPriceFeed).latestRoundData();
       uint256 amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision()))/dsce.getPrecision();
       vm.startPrank(USER);
       uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
       vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBroken.selector, expectedHealthFactor));
       dsce.mintDSC(amountToMint);
       vm.stopPrank();
    }

    function testMintDscRevertsIfMintingAmountIsZero() public collateralDeposited {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.mintDSC(0);
        vm.stopPrank();
    }

    //////////////////////////////
    ///Burn Dsc Tests          ///
    //////////////////////////////
    function testCanBurnDsc() public depositCollateralAndMintedDsc {
        uint256 dscAmountToBurn = 10 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToBurn);
        dsce.burnDsc(dscAmountToBurn);
        vm.stopPrank();
    }

    function testBurnDscRevertsIfBurningAmountIsZero() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDscRevertsIfBurningAmountExceedsBalance() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(101 ether);
        vm.stopPrank();
    }

    //////////////////////////////
    ///Liquidation Tests       ///
    //////////////////////////////
    function testCanLiquidate() public depositCollateralAndMintedDsc {}
}
