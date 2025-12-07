// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        );
}

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 private s_price;
    uint8 private s_decimals;

    constructor(int256 initialPrice, uint8 decimals_) {
        s_price = initialPrice;
        s_decimals = decimals_;
    }

    function setPrice(int256 newPrice) external {
        s_price = newPrice;
    }

    function decimals() external view returns (uint8) {
        return s_decimals;
    }

    function description() external pure returns (string memory) {
        return "MockAggregatorV3";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, s_price, block.timestamp, block.timestamp, 0);
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, s_price, block.timestamp, block.timestamp, 0);
    }
}
