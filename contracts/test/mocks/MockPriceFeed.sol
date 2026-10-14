// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPriceFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 initialAnswer) {
        setPrice(initialAnswer);
    }

    function setPrice(int256 newAnswer) public {
        answer = newAnswer;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 timestamp,
            uint80 answeredInRound
        )
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
