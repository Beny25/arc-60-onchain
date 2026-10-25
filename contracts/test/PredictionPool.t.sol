// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PredictionPool} from "../PredictionPool.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PredictionPoolTest is Test {
    PredictionPool pool;
    MockUSDC usdc;
    MockPriceFeed feed;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    uint256 constant DURATION = 300;
    uint256 constant LOCK = 15;
    uint256 constant MAX_OPEN_STALE = 120;
    uint256 constant FEE = 100; // 1%
    uint256 constant WINDOW = 300; // SETTLE_WINDOW

    PredictionPool.Direction constant UP = PredictionPool.Direction.UP;
    PredictionPool.Direction constant DOWN = PredictionPool.Direction.DOWN;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        feed = new MockPriceFeed(100_000e8);
        pool = new PredictionPool(owner, address(usdc), address(feed), DURATION, LOCK, MAX_OPEN_STALE, FEE);
    }

    // ───────── helpers ─────────

    function _bet(address who, PredictionPool.Direction d, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        pool.bet(pool.currentRoundId(), d, amount);
        vm.stopPrank();
    }

    function _close(int256 price) internal {
        (, , , uint256 closeTime, , , , , ) = pool.rounds(pool.currentRoundId());
        vm.warp(closeTime + 1);
        feed.setPrice(price);
    }

    function _result(uint256 id) internal view returns (PredictionPool.Result r) {
        (, , , , , , , r, ) = pool.rounds(id);
    }

    function _claim(address who, uint256 id) internal returns (uint256 got) {
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        pool.claim(id);
        got = usdc.balanceOf(who) - before;
    }

    // ───────── constructor ─────────

    function testConstructorConfig() public view {
        assertEq(address(pool.usdc()), address(usdc));
        assertEq(pool.priceFeed(), address(feed));
        assertEq(pool.roundDuration(), DURATION);
        assertEq(pool.betLock(), LOCK);
        assertEq(pool.feeBps(), FEE);
    }

    function testConstructorRejectsZeroFeed() public {
        vm.expectRevert(PredictionPool.ZeroAddress.selector);
        new PredictionPool(owner, address(usdc), address(0), DURATION, LOCK, MAX_OPEN_STALE, FEE);
    }

    function testConstructorRejectsZeroUSDC() public {
        vm.expectRevert(PredictionPool.ZeroAddress.selector);
        new PredictionPool(owner, address(0), address(feed), DURATION, LOCK, MAX_OPEN_STALE, FEE);
    }

    function testConstructorRejectsBadConfig() public {
        vm.expectRevert(PredictionPool.InvalidConfig.selector);
        new PredictionPool(owner, address(usdc), address(feed), 59, 0, MAX_OPEN_STALE, FEE);

        vm.expectRevert(PredictionPool.InvalidConfig.selector);
        new PredictionPool(owner, address(usdc), address(feed), DURATION, DURATION, MAX_OPEN_STALE, FEE);

        vm.expectRevert(PredictionPool.InvalidFeeBps.selector);
        new PredictionPool(owner, address(usdc), address(feed), DURATION, LOCK, MAX_OPEN_STALE, 1001);
    }

    // ───────── start ─────────

    function testStartRound() public {
        uint256 id = pool.startRound();
        (int256 open, , uint256 openTime, uint256 closeTime, , , , , bool settled) = pool.rounds(id);
        assertEq(id, 1);
        assertEq(open, 100_000e8);
        assertEq(closeTime, openTime + DURATION);
        assertFalse(settled);
    }

    function testCannotStartBeforeClose() public {
        pool.startRound();
        vm.expectRevert(PredictionPool.CannotStartRound.selector);
        pool.startRound();
    }

    function testStartRejectsStaleOpenPrice() public {
        vm.warp(block.timestamp + MAX_OPEN_STALE + 1);
        vm.expectRevert(PredictionPool.OracleStale.selector);
        pool.startRound();
    }

    function testStartRejectsBadPrice() public {
        feed.setPrice(0);
        vm.expectRevert(PredictionPool.OraclePriceInvalid.selector);
        pool.startRound();
        feed.setPrice(-1);
        vm.expectRevert(PredictionPool.OraclePriceInvalid.selector);
        pool.startRound();
    }

    // ───────── bet ─────────

    function testBetRecordsStake() public {
        pool.startRound();
        _bet(alice, UP, 10e6);
        assertEq(pool.getBet(1, alice, UP), 10e6);
        assertEq(pool.getBet(1, alice, DOWN), 0);
        (, , , , uint256 up, uint256 down, , , ) = pool.rounds(1);
        assertEq(up, 10e6);
        assertEq(down, 0);
    }

    function testOneDirectionPerWallet() public {
        pool.startRound();
        _bet(alice, UP, 10e6);
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(PredictionPool.AlreadyBet.selector);
        pool.bet(1, DOWN, 10e6);
        vm.stopPrank();
    }

    function testBetLockBeforeClose() public {
        pool.startRound();
        vm.warp(block.timestamp + DURATION - LOCK);
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1e6);
        vm.expectRevert(PredictionPool.BettingClosed.selector);
        pool.bet(1, UP, 1e6);
        vm.stopPrank();
    }

    function testBetJustBeforeLockWorks() public {
        pool.startRound();
        vm.warp(block.timestamp + DURATION - LOCK - 1);
        _bet(alice, UP, 1e6);
        assertEq(pool.getBet(1, alice, UP), 1e6);
    }

    function testBetRejectsZeroAndUnknownRound() public {
        vm.expectRevert(PredictionPool.InvalidAmount.selector);
        pool.bet(1, UP, 0);
        vm.expectRevert(PredictionPool.InvalidAmount.selector);
        pool.bet(1, UP, 9_999);
        vm.expectRevert(PredictionPool.RoundNotOpen.selector);
        pool.bet(1, UP, 1e4);
    }

    // ───────── settle ─────────

    function testSettleRequiresPriceAfterClose() public {
        pool.startRound();
        _bet(alice, UP, 1e6);
        _bet(bob, DOWN, 1e6);
        (, , , uint256 closeTime, , , , , ) = pool.rounds(1);
        vm.warp(closeTime + 10); // oracle hasn't updated since open
        vm.expectRevert(PredictionPool.CloseNotPublished.selector);
        pool.settleRound(1);
    }

    function testCannotSettleBeforeClose() public {
        pool.startRound();
        vm.expectRevert(PredictionPool.RoundNotExpired.selector);
        pool.settleRound(1);
    }

    function testCannotSettleAfterWindow() public {
        pool.startRound();
        (, , , uint256 closeTime, , , , , ) = pool.rounds(1);
        vm.warp(closeTime + WINDOW + 1);
        feed.setPrice(101_000e8);
        vm.expectRevert(PredictionPool.SettleWindowPassed.selector);
        pool.settleRound(1);
    }

    function testOneSidedRoundIsVoidAndRefunds() public {
        pool.startRound();
        _bet(alice, UP, 5e6);
        _close(110_000e8);
        pool.settleRound(1);
        assertEq(uint8(_result(1)), uint8(PredictionPool.Result.VOID));
        assertEq(_claim(alice, 1), 5e6);
        assertEq(pool.accruedFees(), 0);
    }

    function testTieRefundsNoFee() public {
        pool.startRound();
        _bet(alice, UP, 3e6);
        _bet(bob, DOWN, 7e6);
        _close(100_000e8);
        pool.settleRound(1);
        assertEq(uint8(_result(1)), uint8(PredictionPool.Result.TIE));
        assertEq(_claim(alice, 1), 3e6);
        assertEq(_claim(bob, 1), 7e6);
        assertEq(pool.accruedFees(), 0);
    }

    function testVoidAfterWindowRefunds() public {
        pool.startRound();
        _bet(alice, UP, 2e6);
        _bet(bob, DOWN, 4e6);
        (, , , uint256 closeTime, , , , , ) = pool.rounds(1);

        vm.warp(closeTime + WINDOW);
        vm.expectRevert(PredictionPool.SettleWindowOpen.selector);
        pool.voidRound(1);

        vm.warp(closeTime + WINDOW + 1);
        pool.voidRound(1);
        assertEq(_claim(alice, 1), 2e6);
        assertEq(_claim(bob, 1), 4e6);
    }

    function testCannotVoidSettledRound() public {
        pool.startRound();
        _bet(alice, UP, 1e6);
        _bet(bob, DOWN, 1e6);
        _close(101_000e8);
        pool.settleRound(1);
        vm.warp(block.timestamp + WINDOW + 10);
        vm.expectRevert(PredictionPool.RoundAlreadySettled.selector);
        pool.voidRound(1);
    }

    // ───────── payouts ─────────

    function testWinnersSplitPoolAfterFee() public {
        pool.startRound();
        _bet(alice, UP, 30e6);
        _bet(carol, UP, 10e6);
        _bet(bob, DOWN, 60e6);
        _close(101_000e8);
        pool.settleRound(1);

        // total 100, fee 1% = 1, reward 99 split 3:1
        assertEq(pool.accruedFees(), 1e6);
        assertEq(pool.claimable(1, alice), 74_250_000);
        assertEq(_claim(alice, 1), 74_250_000);
        assertEq(_claim(carol, 1), 24_750_000);

        vm.prank(bob);
        vm.expectRevert(PredictionPool.NothingToClaim.selector);
        pool.claim(1);
    }

    function testFeeChangeAfterSettleDoesNotAffectRound() public {
        pool.startRound();
        _bet(alice, UP, 50e6);
        _bet(bob, DOWN, 50e6);
        _close(99_000e8);
        pool.settleRound(1);

        pool.setFeeBps(1000);
        assertEq(_claim(bob, 1), 99e6);
    }

    function testDoubleClaimReverts() public {
        pool.startRound();
        _bet(alice, UP, 1e6);
        _bet(bob, DOWN, 1e6);
        _close(101_000e8);
        pool.settleRound(1);
        _claim(alice, 1);
        vm.prank(alice);
        vm.expectRevert(PredictionPool.AlreadyClaimed.selector);
        pool.claim(1);
    }

    function testClaimBeforeSettleReverts() public {
        pool.startRound();
        _bet(alice, UP, 1e6);
        vm.prank(alice);
        vm.expectRevert(PredictionPool.RoundNotSettled.selector);
        pool.claim(1);
    }

    function testCollectFees() public {
        pool.startRound();
        _bet(alice, UP, 50e6);
        _bet(bob, DOWN, 50e6);
        _close(101_000e8);
        pool.settleRound(1);

        pool.collectFees();
        assertEq(usdc.balanceOf(owner), 1e6);

        vm.expectRevert(PredictionPool.NoFeesToCollect.selector);
        pool.collectFees();
    }

    function testOnlyOwnerAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert();
        pool.setFeeBps(10);
        vm.expectRevert();
        pool.collectFees();
        vm.stopPrank();
    }

    // ───────── solvency fuzz ─────────

    function testFuzzPoolStaysSolvent(uint96 a, uint96 b, uint96 c, bool upWins) public {
        uint256 sa = bound(uint256(a), 1e4, 1e12);
        uint256 sb = bound(uint256(b), 1e4, 1e12);
        uint256 sc = bound(uint256(c), 1e4, 1e12);

        pool.startRound();
        _bet(alice, UP, sa);
        _bet(carol, UP, sc);
        _bet(bob, DOWN, sb);
        _close(upWins ? int256(101_000e8) : int256(99_000e8));
        pool.settleRound(1);

        if (upWins) {
            _claim(alice, 1);
            _claim(carol, 1);
        } else {
            _claim(bob, 1);
        }
        pool.collectFees();

        // whatever is left is rounding dust, never a deficit
        assertLe(usdc.balanceOf(address(pool)), 2);
    }
}
