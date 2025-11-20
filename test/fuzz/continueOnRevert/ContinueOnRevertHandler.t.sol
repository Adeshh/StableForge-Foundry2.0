//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";

contract ContinueOnRevertHandler is Test {
    /// forge-config: default.invariant.fail-on-revert = false
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    uint256 public timesMinted;
    uint256 public timesDeposited;
    uint256 public timesRedeemed;
    uint256 public timesDepositedAndMinted;

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
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function depositCollateral(uint256 collateralSeed, uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateral.mint(msg.sender, amount);

        vm.startPrank(msg.sender);
        // Approve the DSCEngine to spend tokens
        collateral.approve(address(dsce), amount);

        // Deposit collateral
        dsce.depositCollateral(address(collateral), amount);
        vm.stopPrank();

        timesDeposited++;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function depositCollateralAndMintDSC(uint256 collateralSeed, uint256 collateralAmount, uint256 dscAmountToMint)
        public
    {
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);
        dscAmountToMint = bound(dscAmountToMint, 0, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        collateral.mint(msg.sender, collateralAmount);

        vm.startPrank(msg.sender);
        // Approve the DSCEngine to spend tokens
        collateral.approve(address(dsce), collateralAmount);

        // Deposit collateral and mint DSC
        dsce.depositCollateralAndMintDSC(address(collateral), collateralAmount, dscAmountToMint);
        vm.stopPrank();

        // Mark this address as having deposited
        timesDepositedAndMinted++;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function mintDSC(uint256 dscAmountToMint) public {
        dscAmountToMint = bound(dscAmountToMint, 0, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        dsce.mintDSC(dscAmountToMint);
        vm.stopPrank();
        timesMinted++;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function redeemCollateral(uint256 collateralSeed, uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amount);
        vm.stopPrank();

        timesRedeemed++;
    }

    ////Helper Functions////
    /// forge-config: default.invariant.fail-on-revert = false
    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
