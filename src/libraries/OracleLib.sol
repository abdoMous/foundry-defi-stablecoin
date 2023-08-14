// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title OracleLib
/// @author abdomo.eth
/// @notice This library is used to check the Chainlink Oracle for stale data.
/// If a price is stale, the function will revert, and render the DSCEngin unusable - this is by design.
/// we want the DSCEngine to freez if prices become stale.
/// So if the Chainlink network explodes and you have a lot of money locked in the protocol ... too bed.
library OracleLib {
    error OracleLib_StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLastestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        uint256 secondsSinceUpdate = block.timestamp - updatedAt;
        if (secondsSinceUpdate > TIMEOUT) {
            revert OracleLib_StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
