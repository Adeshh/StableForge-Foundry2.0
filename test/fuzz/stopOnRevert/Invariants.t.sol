//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployDSC} from "../../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    HelperConfig public config;
    DSCEngine public dsce;
    address weth;
    address wbtc;
    DecentralizedStableCoin public dsc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    uint256 deployerKey;
    Handler public handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));

        // Enable random addresses for fuzz testing
        // Generate 100 different addresses for Foundry to use
        for (uint256 i = 0; i < 100; i++) {
            // Generate deterministic addresses from seeds
            address sender = address(uint160(uint256(keccak256(abi.encodePacked("fuzz_sender", i)))));
            targetSender(sender);
        }
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupplyt() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));
        uint256 totalValueOfWethDeposited = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 totalValueOfWbtcDeposited = dsce.getUsdValue(wbtc, totalWbtcDeposited);
        uint256 totalProtocolValue = totalValueOfWethDeposited + totalValueOfWbtcDeposited;
        console.log("totalSupply", totalSupply);
        console.log("totalProtocolValue", totalProtocolValue);
        console.log("timesMinted", handler.timesMinted());
        console.log("timesDeposited", handler.timesDeposited());
        console.log("timesRedeemed", handler.timesRedeemed());
        console.log("timesDepositedAndMinted", handler.timesDepositedAndMinted());
        assert(totalProtocolValue >= totalSupply);
    }

    function invariant_gettersShouldAlwaysReturn() public view {
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getPrecision();
        dsce.getLiquidationThreshold();
        dsce.getLiquidationPrecision();
        dsce.getLiquidationBonus();
        dsce.getCollateralDeposited(address(this), weth);
        dsce.getDscMinted(address(this));
        dsce.getAdditionalFeedPrecision();
    }
}
