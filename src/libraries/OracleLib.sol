//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author @Adeshh
 * @notice Library for getting the price of a token from a price feed Also Checks if the price is older/not updated.
 *         If the price is older than heartbeat period, it reverts and make DSCEngine unusable.
 */
library OracleLib {
    uint256 public constant TIMEOUT = 3 hours;

    error OracleLib__InvalidPrice();
    error OracleLib__StalePrice();

    /**
     * 
     * @param priceFeed - The price feed to check the latest round data for
     * @return roundId - The round id of the latest round
     * @return answer - The answer of the latest round
     * @return startedAt - The started at time of the latest round
     * @return updatedAt - The updated at time of the latest round
     * @return answeredInRound - The answered in round of the latest round
     * @notice - This function checks if the price is stale and if it is, it reverts.
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        uint256 secondsSinceUpdate = block.timestamp - updatedAt;
        if (secondsSinceUpdate > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getDecimals(address priceFeed) public view returns (uint256) {
        return AggregatorV3Interface(priceFeed).decimals();
    }
}
