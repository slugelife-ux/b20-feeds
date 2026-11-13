// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {B20FeedRegistry} from "./B20FeedRegistry.sol";

/// @title B20FeedProxy
/// @notice Per-feed AggregatorV3-compatible read surface over
///         B20FeedRegistry, deployed by the registry at register() time.
///         Developers who already read Chainlink feeds swap this address in
///         and change nothing else.
contract B20FeedProxy {
    B20FeedRegistry public immutable registry;
    uint256 public immutable feedId;

    constructor(B20FeedRegistry registry_, uint256 feedId_) {
        registry = registry_;
        feedId = feedId_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (registry.proxyOf(feedId) == address(0)) revert B20FeedRegistry.FeedNotRegistered(feedId);
        roundId = registry.roundIdOf(feedId);
        answer = registry.answerOf(feedId);
        startedAt = registry.startedAtOf(feedId);
        updatedAt = registry.updatedAtOf(feedId);
        answeredInRound = roundId;
    }

    /// @notice Full AggregatorV3 historical round read.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (int256 a, uint64 s, uint64 u) = registry.getRound(feedId, _roundId);
        roundId = _roundId;
        answer = a;
        startedAt = s;
        updatedAt = u;
        answeredInRound = _roundId;
    }

    function latestAnswer() external view returns (int256) {
        return registry.answerOf(feedId);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return registry.descriptionOf(feedId);
    }

    /// @notice The B20 token this feed prices (identifier of record on Base —
    ///         tokens are address-indexed, never symbol-indexed).
    function token() external view returns (address) {
        return registry.tokenOf(feedId);
    }
}
