// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PredictionPool} from "../PredictionPool.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PredictionPoolTest is Test {
    PredictionPool pool;

    MockUSDC mockUSDC;
    MockPriceFeed mockPriceFeed;

    address owner = address(this);
    address usdc = address(0x1234);
    address priceFeed = address(0x5678);

    function setUp() public {
        mockUSDC = new MockUSDC();
        mockPriceFeed = new MockPriceFeed(100_000e8);

        pool = new PredictionPool(
            owner,
            address(mockUSDC),
            address(mockPriceFeed),
            100
        );
    }

    function testConstructorSetsConfiguration() public {
        assertEq(address(pool.usdc()), address(mockUSDC));
        assertEq(pool.priceFeed(), address(mockPriceFeed));
        assertEq(pool.feeBps(), 100);
        assertEq(pool.currentRoundId(), 0);
    }

    function testConstructorRejectsZeroUSDC() public {
        vm.expectRevert(PredictionPool.ZeroAddress.selector);

        new PredictionPool(
            owner,
            address(0),
            priceFeed,
           100
        );
    }

    function testConstructorRejectsFeeAboveMaximum() public {
        vm.expectRevert(PredictionPool.InvalidFeeBps.selector);

        new PredictionPool(
            owner,
            usdc,
            priceFeed,
            1001
        );
    }

    function testStartRoundOpensFirstRound() public {
        uint256 roundId = pool.startRound();

        (
            int256 openPrice,
            ,
            uint256 openTime,
            uint256 closeTime,
            ,
            ,
            ,
            bool settled
        ) = pool.rounds(roundId);

        assertEq(roundId, 1);
        assertEq(openPrice, 100_000e8);
        assertEq(openTime, block.timestamp);
        assertEq(closeTime, openTime + 60);
        assertFalse(settled);
    }

    function testCannotStartNextRoundBeforeCurrentExpires() public {
        pool.startRound();

        vm.expectRevert(PredictionPool.CannotStartRound.selector);
        pool.startRound();
    }

    function testCanStartNextRoundAfterCurrentExpires() public {
        uint256 firstRoundId = pool.startRound();

        vm.warp(block.timestamp + 60);

        uint256 secondRoundId = pool.startRound();

        assertEq(firstRoundId, 1);
        assertEq(secondRoundId, 2);
        assertEq(pool.currentRoundId(), 2);
    }

    function testStartRoundRejectsZeroOraclePrice() public {
        mockPriceFeed.setPrice(0);

        vm.expectRevert(PredictionPool.OraclePriceInvalid.selector);
        pool.startRound();
    }

function testStartRoundRejectsNegativeOraclePrice() public {
    mockPriceFeed.setPrice(-1);

    vm.expectRevert(PredictionPool.OraclePriceInvalid.selector);
    pool.startRound();
}

    function testStartRoundRejectsStaleOraclePrice() public {
        vm.warp(block.timestamp + 3601);

        vm.expectRevert(PredictionPool.OracleStale.selector);
        pool.startRound();
    }

function testBetPlacesUpBet() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();

    mockUSDC.mint(alice, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

uint256 betAmount = pool.getBet(
    1,
    alice,
    PredictionPool.Direction.UP
);

assertEq(betAmount, amount);
    assertEq(mockUSDC.balanceOf(address(pool)), amount);
}

function testCannotBetTwiceOnSameDirection() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, 2 * amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), 2 * amount);

    pool.bet(1, PredictionPool.Direction.UP, amount);

    vm.expectRevert(PredictionPool.AlreadyBet.selector);
    pool.bet(1, PredictionPool.Direction.UP, amount);

    vm.stopPrank();

    assertEq(
        pool.getBet(1, alice, PredictionPool.Direction.UP),
        amount
    );
    assertEq(mockUSDC.balanceOf(address(pool)), amount);
}

function testCanBetOnBothDirections() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, 2 * amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), 2 * amount);

    pool.bet(1, PredictionPool.Direction.UP, amount);
    pool.bet(1, PredictionPool.Direction.DOWN, amount);

    vm.stopPrank();

    assertEq(
        pool.getBet(1, alice, PredictionPool.Direction.UP),
        amount
    );
    assertEq(
        pool.getBet(1, alice, PredictionPool.Direction.DOWN),
        amount
    );
    assertEq(mockUSDC.balanceOf(address(pool)), 2 * amount);
}

function testCannotBetZeroAmount() public {
    address alice = address(0xA11CE);

    pool.startRound();

    vm.prank(alice);
    vm.expectRevert(PredictionPool.InvalidAmount.selector);
    pool.bet(1, PredictionPool.Direction.UP, 0);
}

function testCannotBetAfterRoundCloses() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, amount);

    vm.warp(block.timestamp + 60);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);

    vm.expectRevert(PredictionPool.RoundNotOpen.selector);
    pool.bet(1, PredictionPool.Direction.UP, amount);

    vm.stopPrank();

    assertEq(mockUSDC.balanceOf(address(pool)), 0);
}

function testCannotSettleBeforeRoundExpires() public {
    pool.startRound();

    vm.expectRevert(PredictionPool.RoundNotExpired.selector);
    pool.settleRound(1);
}

function testSettleRoundWithHigherPriceResultsInUp() public {
    pool.startRound();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(101_000e8);

    pool.settleRound(1);

    (
        int256 openPrice,
        int256 closePrice,
        ,
        ,
        ,
        ,
        PredictionPool.Result result,
        bool settled
    ) = pool.rounds(1);

    assertEq(openPrice, 100_000e8);
    assertEq(closePrice, 101_000e8);
    assertEq(uint256(result), uint256(PredictionPool.Result.UP));
    assertTrue(settled);
}

function testSettleRoundWithLowerPriceResultsInDown() public {
    pool.startRound();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(99_000e8);

    pool.settleRound(1);

    (
        ,
        int256 closePrice,
        ,
        ,
        ,
        ,
        PredictionPool.Result result,
        bool settled
    ) = pool.rounds(1);

    assertEq(closePrice, 99_000e8);
    assertEq(uint256(result), uint256(PredictionPool.Result.DOWN));
    assertTrue(settled);
}

function testSettleRoundWithSamePriceResultsInTie() public {
    pool.startRound();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(100_000e8);

    pool.settleRound(1);

    (
        ,
        int256 closePrice,
        ,
        ,
        ,
        ,
        PredictionPool.Result result,
        bool settled
    ) = pool.rounds(1);

    assertEq(closePrice, 100_000e8);
    assertEq(uint256(result), uint256(PredictionPool.Result.TIE));
    assertTrue(settled);
}

function testCannotClaimBeforeRoundIsSettled() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);

    vm.expectRevert(PredictionPool.RoundNotSettled.selector);
    pool.claim(1);

    vm.stopPrank();

    assertEq(mockUSDC.balanceOf(alice), 0);
    assertEq(mockUSDC.balanceOf(address(pool)), amount);
}

function testWinnerReceivesPayoutAfterFee() public {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 amount = 10e6; // 10 USDC (6 decimals)

    pool.startRound();

    mockUSDC.mint(alice, amount);
    mockUSDC.mint(bob, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

    vm.startPrank(bob);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.DOWN, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(101_000e8);

    pool.settleRound(1);

    vm.prank(alice);
    pool.claim(1);

    assertEq(mockUSDC.balanceOf(alice), 19_800_000);
    assertEq(pool.accruedFees(), 200_000);
}

function testCannotClaimTwice() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(101_000e8);
    pool.settleRound(1);

    vm.startPrank(alice);
    pool.claim(1);

    vm.expectRevert(PredictionPool.AlreadyClaimed.selector);
    pool.claim(1);
    vm.stopPrank();
}

function testLoserCannotClaimPayout() public {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 amount = 10e6;

    pool.startRound();

    mockUSDC.mint(alice, amount);
    mockUSDC.mint(bob, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

    vm.startPrank(bob);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.DOWN, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(99_000e8);
    pool.settleRound(1);

    vm.prank(alice);
    vm.expectRevert(PredictionPool.NothingToClaim.selector);
    pool.claim(1);

    assertEq(mockUSDC.balanceOf(alice), 0);
}

function testTieRefundsBetToPlayer() public {
    address alice = address(0xA11CE);
    uint256 amount = 10e6;

    pool.startRound();
    mockUSDC.mint(alice, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(100_000e8);
    pool.settleRound(1);

    vm.prank(alice);
    pool.claim(1);

    assertEq(mockUSDC.balanceOf(alice), amount);
    assertEq(mockUSDC.balanceOf(address(pool)), 0);
}

function testTieRefundsBothDirections() public {
    address alice = address(0xA11CE);
    uint256 upAmount = 10e6;
    uint256 downAmount = 5e6;
    uint256 totalBet = upAmount + downAmount;

    pool.startRound();
    mockUSDC.mint(alice, totalBet);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), totalBet);
    pool.bet(1, PredictionPool.Direction.UP, upAmount);
    pool.bet(1, PredictionPool.Direction.DOWN, downAmount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(100_000e8);
    pool.settleRound(1);

    vm.prank(alice);
    pool.claim(1);

    assertEq(mockUSDC.balanceOf(alice), totalBet);
    assertEq(mockUSDC.balanceOf(address(pool)), 0);

    assertEq(
        pool.getBet(1, alice, PredictionPool.Direction.UP),
        upAmount
    );
    assertEq(
        pool.getBet(1, alice, PredictionPool.Direction.DOWN),
        downAmount
    );
}

function testOwnerCanCollectAccruedFees() public {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 amount = 10e6;

    pool.startRound();

    mockUSDC.mint(alice, amount);
    mockUSDC.mint(bob, amount);

    vm.startPrank(alice);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.UP, amount);
    vm.stopPrank();

    vm.startPrank(bob);
    mockUSDC.approve(address(pool), amount);
    pool.bet(1, PredictionPool.Direction.DOWN, amount);
    vm.stopPrank();

    vm.warp(block.timestamp + 60);
    mockPriceFeed.setPrice(101_000e8);
    pool.settleRound(1);

    vm.prank(alice);
    pool.claim(1);

    assertEq(pool.accruedFees(), 200_000);

    uint256 ownerBalanceBefore = mockUSDC.balanceOf(owner);

    pool.collectFees();

    assertEq(pool.accruedFees(), 0);
    assertEq(
        mockUSDC.balanceOf(owner),
        ownerBalanceBefore + 200_000
    );
}

function testNonOwnerCannotCollectFees() public {
    address stranger = address(0xBAD);

    vm.prank(stranger);
    vm.expectRevert();
    pool.collectFees();
}

function testCannotCollectFeesWhenEmpty() public {
    vm.expectRevert(PredictionPool.NoFeesToCollect.selector);
    pool.collectFees();
}

function testCannotStartRoundWithoutOracle() public {
    pool.setPriceFeed(address(0));

    vm.expectRevert(PredictionPool.OracleNotConfigured.selector);
    pool.startRound();
}

function testNonOwnerCannotChangePriceFeed() public {
    address stranger = address(0xBAD);
    address newFeed = address(0x9999);

    vm.prank(stranger);
    vm.expectRevert();
    pool.setPriceFeed(newFeed);

    assertEq(pool.priceFeed(), address(mockPriceFeed));
}

function testOwnerCanChangePriceFeed() public {
    address newFeed = address(0x9999);

    pool.setPriceFeed(newFeed);

    assertEq(pool.priceFeed(), newFeed);
}

function testStartRoundRejectsFutureOracleTimestamp() public {
    vm.warp(1_000_000);
    vm.warp(block.timestamp + 100);

    mockPriceFeed.setPrice(100_000e8);

    vm.warp(block.timestamp - 100);

    vm.expectRevert(PredictionPool.OraclePriceInvalid.selector);
    pool.startRound();
}

function testSettlementUsesPriceAtSettlementTime() public {
    pool.startRound();

    // Ronde berakhir setelah 60 detik.
    vm.warp(block.timestamp + 60);

    // Settlement terlambat 15 detik.
    vm.warp(block.timestamp + 15);

    // Mock memberikan harga pada waktu settlement.
    mockPriceFeed.setPrice(99_000e8);

    pool.settleRound(1);

    (, int256 closePrice,,,,,,) = pool.rounds(1);
    assertEq(closePrice, 99_000e8);
}

}
