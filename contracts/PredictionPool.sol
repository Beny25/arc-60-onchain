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

/// @title ARC 60 PredictionPool (v2)
/// @notice Parimutuel BTC up/down rounds settled in USDC.
/// Changes vs v1:
///  - price feed is immutable, no manual/owner settlement path
///  - close price must be an oracle update published inside [closeTime, closeTime + SETTLE_WINDOW]
///  - a round that can't be settled in that window can be voided by anyone -> full refunds
///  - one-sided rounds are voided (refund, no fee)
///  - one direction per wallet per round, minimum bet 0.01 USDC
///  - betting locks `betLock` seconds before close
///  - fee and reward pool are snapshotted at settlement (owner fee changes can't touch settled rounds)
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
        TIE,
        VOID
    }

    struct Round {
        int256 openPrice;
        int256 closePrice;
        uint256 openTime;
        uint256 closeTime;
        uint256 totalUp;
        uint256 totalDown;
        uint256 rewardPool; // total pool minus fee, set when a winner is decided
        Result result;
        bool settled;
    }

    struct Bet {
        uint256 amount;
        Direction direction;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant MIN_ROUND_DURATION = 60;
    uint256 public constant SETTLE_WINDOW = 300;
    uint256 public constant MIN_BET = 10_000; // 0.01 USDC, keeps winner payouts from rounding to 0

    IERC20 public immutable usdc;
    address public immutable priceFeed;
    uint256 public immutable roundDuration;
    uint256 public immutable betLock;
    uint256 public immutable maxOpenStaleness;

    uint256 public currentRoundId;
    uint256 public feeBps;
    uint256 public accruedFees;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => Bet)) private _bets;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    error RoundNotOpen();
    error BettingClosed();
    error RoundNotExpired();
    error AlreadyBet();
    error AlreadyClaimed();
    error RoundNotSettled();
    error InvalidAmount();
    error OraclePriceInvalid();
    error OracleStale();
    error CloseNotPublished();
    error SettleWindowPassed();
    error SettleWindowOpen();
    error InvalidFeeBps();
    error InvalidConfig();
    error NothingToClaim();
    error NoFeesToCollect();
    error RoundAlreadySettled();
    error CannotStartRound();
    error ZeroAddress();

    event RoundStarted(uint256 indexed roundId, int256 openPrice, uint256 closeTime);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, Direction direction, uint256 amount);
    event RoundSettled(uint256 indexed roundId, int256 closePrice, Result result);
    event RoundVoided(uint256 indexed roundId);
    event Claimed(uint256 indexed roundId, address indexed claimer, uint256 amount);
    event FeeBpsUpdated(uint256 newFeeBps);
    event FeesCollected(address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address usdcToken,
        address priceFeed_,
        uint256 roundDuration_,
        uint256 betLock_,
        uint256 maxOpenStaleness_,
        uint256 initialFeeBps
    ) Ownable(initialOwner) {
        if (usdcToken == address(0) || priceFeed_ == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        if (roundDuration_ < MIN_ROUND_DURATION || betLock_ >= roundDuration_ || maxOpenStaleness_ == 0) {
            revert InvalidConfig();
        }

        usdc = IERC20(usdcToken);
        priceFeed = priceFeed_;
        roundDuration = roundDuration_;
        betLock = betLock_;
        maxOpenStaleness = maxOpenStaleness_;
        feeBps = initialFeeBps;
    }

    // ───────────────────────────── rounds ─────────────────────────────

    function startRound() external returns (uint256 newRoundId) {
        if (currentRoundId != 0 && block.timestamp < rounds[currentRoundId].closeTime) {
            revert CannotStartRound();
        }

        (int256 openPrice, uint256 updatedAt) = _readOracle();
        if (block.timestamp - updatedAt > maxOpenStaleness) revert OracleStale();

        newRoundId = currentRoundId + 1;
        currentRoundId = newRoundId;

        Round storage round = rounds[newRoundId];
        round.openPrice = openPrice;
        round.openTime = block.timestamp;
        round.closeTime = block.timestamp + roundDuration;

        emit RoundStarted(newRoundId, openPrice, round.closeTime);
    }

    function bet(uint256 roundId, Direction direction, uint256 amount) external nonReentrant {
        if (amount < MIN_BET) revert InvalidAmount();

        Round storage round = rounds[roundId];
        if (round.openTime == 0 || block.timestamp >= round.closeTime) revert RoundNotOpen();
        if (block.timestamp >= round.closeTime - betLock) revert BettingClosed();

        Bet storage b = _bets[roundId][msg.sender];
        if (b.amount != 0) revert AlreadyBet();

        b.amount = amount;
        b.direction = direction;

        if (direction == Direction.UP) {
            round.totalUp += amount;
        } else {
            round.totalDown += amount;
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit BetPlaced(roundId, msg.sender, direction, amount);
    }

    /// @notice Anyone can settle once the oracle has published a price at/after closeTime,
    /// as long as that update (and this call) happen within SETTLE_WINDOW of close.
    function settleRound(uint256 roundId) external {
        Round storage round = rounds[roundId];

        if (round.openTime == 0) revert RoundNotOpen();
        if (round.settled) revert RoundAlreadySettled();
        if (block.timestamp < round.closeTime) revert RoundNotExpired();
        if (block.timestamp > round.closeTime + SETTLE_WINDOW) revert SettleWindowPassed();

        (int256 closePrice, uint256 updatedAt) = _readOracle();
        if (updatedAt < round.closeTime) revert CloseNotPublished();

        round.closePrice = closePrice;
        round.settled = true;

        uint256 total = round.totalUp + round.totalDown;
        Result result;
        if (round.totalUp == 0 || round.totalDown == 0) {
            result = Result.VOID; // nobody to win against -> refund
        } else if (closePrice > round.openPrice) {
            result = Result.UP;
        } else if (closePrice < round.openPrice) {
            result = Result.DOWN;
        } else {
            result = Result.TIE;
        }
        round.result = result;

        if (result == Result.UP || result == Result.DOWN) {
            uint256 fee = (total * feeBps) / BPS_DENOMINATOR;
            accruedFees += fee;
            round.rewardPool = total - fee;
        }

        emit RoundSettled(roundId, closePrice, result);
    }

    /// @notice If nobody could settle inside the window (oracle silent, keeper down), refund everyone.
    function voidRound(uint256 roundId) external {
        Round storage round = rounds[roundId];

        if (round.openTime == 0) revert RoundNotOpen();
        if (round.settled) revert RoundAlreadySettled();
        if (block.timestamp <= round.closeTime + SETTLE_WINDOW) revert SettleWindowOpen();

        round.settled = true;
        round.result = Result.VOID;

        emit RoundVoided(roundId);
    }

    function claim(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];

        if (!round.settled) revert RoundNotSettled();
        if (hasClaimed[roundId][msg.sender]) revert AlreadyClaimed();

        Bet memory b = _bets[roundId][msg.sender];
        if (b.amount == 0) revert NothingToClaim();

        uint256 payout;
        Result result = round.result;

        if (result == Result.TIE || result == Result.VOID) {
            payout = b.amount;
        } else {
            bool won = (result == Result.UP && b.direction == Direction.UP)
                || (result == Result.DOWN && b.direction == Direction.DOWN);
            if (!won) revert NothingToClaim();

            uint256 winningPool = result == Result.UP ? round.totalUp : round.totalDown;
            payout = (round.rewardPool * b.amount) / winningPool;
        }

        if (payout == 0) revert NothingToClaim();

        hasClaimed[roundId][msg.sender] = true;
        usdc.safeTransfer(msg.sender, payout);

        emit Claimed(roundId, msg.sender, payout);
    }

    // ───────────────────────────── admin ─────────────────────────────

    /// @notice Only affects rounds settled after the change.
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        feeBps = newFeeBps;
        emit FeeBpsUpdated(newFeeBps);
    }

    function collectFees() external onlyOwner nonReentrant {
        uint256 fees = accruedFees;
        if (fees == 0) revert NoFeesToCollect();

        accruedFees = 0;
        usdc.safeTransfer(owner(), fees);
        emit FeesCollected(owner(), fees);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Kept for frontend compatibility: returns the stake only if it was on `direction`.
    function getBet(uint256 roundId, address bettor, Direction direction) external view returns (uint256) {
        Bet memory b = _bets[roundId][bettor];
        return b.direction == direction ? b.amount : 0;
    }

    function getUserBet(uint256 roundId, address bettor) external view returns (uint256 amount, Direction direction) {
        Bet memory b = _bets[roundId][bettor];
        return (b.amount, b.direction);
    }

    function claimable(uint256 roundId, address bettor) external view returns (uint256) {
        Round storage round = rounds[roundId];
        Bet memory b = _bets[roundId][bettor];
        if (!round.settled || b.amount == 0 || hasClaimed[roundId][bettor]) return 0;

        if (round.result == Result.TIE || round.result == Result.VOID) return b.amount;
        if (round.result == Result.UP && b.direction == Direction.UP) {
            return (round.rewardPool * b.amount) / round.totalUp;
        }
        if (round.result == Result.DOWN && b.direction == Direction.DOWN) {
            return (round.rewardPool * b.amount) / round.totalDown;
        }
        return 0;
    }

    // ───────────────────────────── internal ─────────────────────────────

    function _readOracle() internal view returns (int256 answer, uint256 updatedAt) {
        (, answer, , updatedAt, ) = AggregatorV3Interface(priceFeed).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert OraclePriceInvalid();
    }
}
