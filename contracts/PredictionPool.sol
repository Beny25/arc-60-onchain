// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract PredictionPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Direction {
        UP,
        DOWN
    }

    enum Result {
        UNSET,
        UP,
        DOWN,
        TIE
    }

    struct Round {
        int256 openPrice;
        int256 closePrice;
        uint256 openTime;
        uint256 closeTime;
        uint256 totalUp;
        uint256 totalDown;
        Result result;
        bool settled;
    }

    uint256 public constant ROUND_DURATION = 60;
    uint256 public constant MAX_ORACLE_STALENESS = 3600;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;

    IERC20 public immutable usdc;
    address public priceFeed;

    uint256 public currentRoundId;
    uint256 public feeBps;
    uint256 public accruedFees;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => mapping(Direction => uint256))) private _bets;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    error RoundNotOpen();
    error RoundNotExpired();
    error AlreadyBet();
    error AlreadyClaimed();
    error RoundNotSettled();
    error InvalidAmount();
    error OracleNotConfigured();
    error OraclePriceInvalid();
    error OracleStale();
    error ManualSettleNotAllowed();
    error InvalidFeeBps();
    error NothingToClaim();
    error NoFeesToCollect();
    error RoundAlreadySettled();
    error CannotStartRound();
    error ZeroAddress();

    event RoundStarted(uint256 indexed roundId, int256 openPrice, uint256 closeTime);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, Direction direction, uint256 amount);
    event RoundSettled(uint256 indexed roundId, int256 closePrice, Result result);
    event Claimed(uint256 indexed roundId, address indexed claimer, uint256 amount);
    event PriceFeedUpdated(address newFeed);
    event FeeBpsUpdated(uint256 newFeeBps);

    /// @notice Deployer must supply the Arc Testnet BTC/USD Chainlink feed address:
    /// https://docs.chain.link/data-feeds/price-feeds/addresses?network=arc
    /// If priceFeed is address(0), oracle settlement is disabled and owner-only
    /// `settleWithManualPrice` is the fallback settlement path.
    constructor(address initialOwner, address usdcToken, address initialPriceFeed, uint256 initialFeeBps) Ownable(initialOwner) {
        if (usdcToken == address(0)) {
            revert ZeroAddress();
        }
        if (initialFeeBps > MAX_FEE_BPS) {
            revert InvalidFeeBps();
        }

        usdc = IERC20(usdcToken);
        priceFeed = initialPriceFeed;
        feeBps = initialFeeBps;
    }

    function startRound() external returns (uint256 newRoundId) {
        if (priceFeed == address(0)) {
            revert OracleNotConfigured();
        }

        if (currentRoundId != 0) {
            Round storage current = rounds[currentRoundId];
            if (!current.settled && block.timestamp < current.closeTime) {
                revert CannotStartRound();
            }
        }

        int256 openPrice = _readValidatedOraclePrice();

        newRoundId = currentRoundId + 1;
        currentRoundId = newRoundId;

        Round storage round = rounds[newRoundId];
        round.openPrice = openPrice;
        round.openTime = block.timestamp;
        round.closeTime = block.timestamp + ROUND_DURATION;

        emit RoundStarted(newRoundId, openPrice, round.closeTime);
    }

    function bet(uint256 roundId, Direction direction, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }

        Round storage round = rounds[roundId];
        if (round.openTime == 0 || block.timestamp >= round.closeTime) {
            revert RoundNotOpen();
        }

        if (_bets[roundId][msg.sender][direction] != 0) {
            revert AlreadyBet();
        }

        _bets[roundId][msg.sender][direction] = amount;

        if (direction == Direction.UP) {
            round.totalUp += amount;
        } else {
            round.totalDown += amount;
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit BetPlaced(roundId, msg.sender, direction, amount);
    }

    function settleRound(uint256 roundId) external {
        Round storage round = rounds[roundId];

        if (round.openTime == 0) {
            revert RoundNotOpen();
        }
        if (round.settled) {
            revert RoundAlreadySettled();
        }
        if (block.timestamp < round.closeTime) {
            revert RoundNotExpired();
        }
        if (priceFeed == address(0)) {
            revert OracleNotConfigured();
        }

        int256 closePrice = _readValidatedOraclePrice();
        _settleRound(roundId, round, closePrice);
    }

    function settleWithManualPrice(uint256 roundId, int256 closePrice) external onlyOwner {
        if (priceFeed != address(0)) {
            revert ManualSettleNotAllowed();
        }
        if (closePrice <= 0) {
            revert OraclePriceInvalid();
        }

        Round storage round = rounds[roundId];

        if (round.openTime == 0) {
            revert RoundNotOpen();
        }
        if (round.settled) {
            revert RoundAlreadySettled();
        }
        if (block.timestamp < round.closeTime) {
            revert RoundNotExpired();
        }

        _settleRound(roundId, round, closePrice);
    }

    function claim(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];

        if (!round.settled) {
            revert RoundNotSettled();
        }
        if (hasClaimed[roundId][msg.sender]) {
            revert AlreadyClaimed();
        }

        uint256 upBet = _bets[roundId][msg.sender][Direction.UP];
        uint256 downBet = _bets[roundId][msg.sender][Direction.DOWN];

        if (upBet == 0 && downBet == 0) {
            revert NothingToClaim();
        }

        uint256 payout;

        if (round.result == Result.TIE) {
            payout = upBet + downBet;
        } else if (round.result == Result.UP) {
            if (upBet == 0) {
                revert NothingToClaim();
            }
            payout = _calculateWinnerPayout(upBet, round.totalUp, round.totalUp + round.totalDown);
        } else if (round.result == Result.DOWN) {
            if (downBet == 0) {
                revert NothingToClaim();
            }
            payout = _calculateWinnerPayout(downBet, round.totalDown, round.totalUp + round.totalDown);
        } else {
            revert RoundNotSettled();
        }

        if (payout == 0) {
            revert NothingToClaim();
        }

        hasClaimed[roundId][msg.sender] = true;
        usdc.safeTransfer(msg.sender, payout);

        emit Claimed(roundId, msg.sender, payout);
    }

    function setPriceFeed(address newFeed) external onlyOwner {
        priceFeed = newFeed;
        emit PriceFeedUpdated(newFeed);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) {
            revert InvalidFeeBps();
        }
        feeBps = newFeeBps;
        emit FeeBpsUpdated(newFeeBps);
    }

    function collectFees() external onlyOwner nonReentrant {
        uint256 fees = accruedFees;
        if (fees == 0) {
            revert NoFeesToCollect();
        }

        accruedFees = 0;
        usdc.safeTransfer(owner(), fees);
    }

    function getBet(uint256 roundId, address bettor, Direction direction) external view returns (uint256) {
        return _bets[roundId][bettor][direction];
    }

    function _settleRound(uint256 roundId, Round storage round, int256 closePrice) internal {
        round.closePrice = closePrice;
        round.settled = true;

        if (closePrice > round.openPrice) {
            round.result = Result.UP;
        } else if (closePrice < round.openPrice) {
            round.result = Result.DOWN;
        } else {
            round.result = Result.TIE;
        }

        emit RoundSettled(roundId, closePrice, round.result);
    }

    function _readValidatedOraclePrice() internal view returns (int256 answer) {
        uint256 updatedAt;
        (, answer, , updatedAt, ) = AggregatorV3Interface(priceFeed).latestRoundData();

        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert OraclePriceInvalid();
        }

        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
            revert OracleStale();
        }
    }

    function _calculateWinnerPayout(uint256 userStake, uint256 winningPool, uint256 totalPool)
        internal
        returns (uint256 payout)
    {
        uint256 grossShare = (totalPool * userStake) / winningPool;
        uint256 fee = (grossShare * feeBps) / BPS_DENOMINATOR;

        if (fee != 0) {
            accruedFees += fee;
        }

        payout = grossShare - fee;
    }
}
