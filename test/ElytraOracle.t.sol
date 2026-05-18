// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}         from "forge-std/Test.sol";
import {ElytraOracle} from "../src/ElytraOracle.sol";

contract ElytraOracleTest is Test {
    ElytraOracle internal oracle;

    address internal constant ATTESTER     = address(0xA77E51E4);
    address internal constant NON_ATTESTER = address(0xBADBABE);
    address internal constant TARGET       = address(0x1234);

    bytes32 internal constant UID_A = bytes32(uint256(0xAAAA));
    bytes32 internal constant UID_B = bytes32(uint256(0xBBBB));

    uint64  internal constant CHAIN_BASE   = 8453;
    uint64  internal constant CHAIN_ETH    = 1;

    /// @dev Mirror the event signature so vm.expectEmit can match.
    event Scored(
        address indexed target,
        uint32  indexed chainId,
        uint8           score,
        bytes32         easUid,
        uint64          timestamp
    );

    function setUp() public {
        // Warp to a non-zero, realistic timestamp so uint64(block.timestamp) > 0
        vm.warp(1_700_000_000);
        oracle = new ElytraOracle(ATTESTER);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────

    function test_attesterIsImmutableAndPublic() public view {
        assertEq(oracle.attester(), ATTESTER);
    }

    function test_constructorRejectsZeroAttester() public {
        vm.expectRevert(ElytraOracle.ZeroAttester.selector);
        new ElytraOracle(address(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Happy path
    // ─────────────────────────────────────────────────────────────────────

    function test_publishFirstScore_storesAllFields() public {
        uint64 ts = uint64(block.timestamp) - 60;

        vm.expectEmit(true, true, false, true, address(oracle));
        emit Scored(TARGET, uint32(CHAIN_BASE), uint8(88), UID_A, ts);

        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 88, UID_A, ts, uint32(CHAIN_BASE));

        ElytraOracle.Score memory s = oracle.scoreOf(TARGET);
        assertEq(s.score,              88,                 "score");
        assertEq(s.easUid,             UID_A,              "easUid");
        assertEq(uint256(s.timestamp), uint256(ts),        "timestamp");
        assertEq(uint256(s.chainId),   CHAIN_BASE,         "chainId");
    }

    function test_overwriteUpdatesAllFields() public {
        uint64 ts1 = uint64(block.timestamp) - 1 days;
        uint64 ts2 = uint64(block.timestamp) - 1 hours;

        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 88, UID_A, ts1, uint32(CHAIN_BASE));

        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 42, UID_B, ts2, uint32(CHAIN_ETH));

        ElytraOracle.Score memory s = oracle.scoreOf(TARGET);
        assertEq(s.score,              42,           "score after overwrite");
        assertEq(s.easUid,             UID_B,        "uid after overwrite");
        assertEq(uint256(s.timestamp), uint256(ts2), "ts after overwrite");
        assertEq(uint256(s.chainId),   CHAIN_ETH,    "chainId after overwrite");
    }

    function test_idempotentSameValues_succeeds() public {
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 88, UID_A, ts, uint32(CHAIN_BASE));
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 88, UID_A, ts, uint32(CHAIN_BASE));
        ElytraOracle.Score memory s = oracle.scoreOf(TARGET);
        assertEq(s.score, 88);
    }

    function test_unknownAddress_returnsZeroStruct() public view {
        ElytraOracle.Score memory s = oracle.scoreOf(address(0xDEAD));
        assertEq(s.score,              0);
        assertEq(s.easUid,             bytes32(0));
        assertEq(uint256(s.timestamp), 0);
        assertEq(uint256(s.chainId),   0);
    }

    function test_boundary_score100_succeeds() public {
        uint64 ts = uint64(block.timestamp);
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 100, UID_A, ts, uint32(CHAIN_BASE));
        assertEq(oracle.scoreOf(TARGET).score, 100);
    }

    function test_boundary_score0_succeeds() public {
        uint64 ts = uint64(block.timestamp);
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 0, UID_A, ts, uint32(CHAIN_BASE));
        ElytraOracle.Score memory s = oracle.scoreOf(TARGET);
        assertEq(s.score, 0);
        // Non-zero timestamp distinguishes "scored 0" from "never scored".
        assertGt(uint256(s.timestamp), 0);
    }

    function test_timestampAtBlockTimestamp_succeeds() public {
        uint64 ts = uint64(block.timestamp);
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 50, UID_A, ts, uint32(CHAIN_BASE));
        assertEq(uint256(oracle.scoreOf(TARGET).timestamp), uint256(ts));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Reverts
    // ─────────────────────────────────────────────────────────────────────

    function test_nonAttesterCannotPublish() public {
        vm.prank(NON_ATTESTER);
        vm.expectRevert(ElytraOracle.NotAttester.selector);
        oracle.publishScore(TARGET, 50, UID_A, uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function test_scoreOver100_reverts() public {
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ScoreTooHigh.selector);
        oracle.publishScore(TARGET, 101, UID_A, uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function test_zeroTarget_reverts() public {
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ZeroTarget.selector);
        oracle.publishScore(address(0), 50, UID_A, uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function test_zeroUid_reverts() public {
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ZeroUid.selector);
        oracle.publishScore(TARGET, 50, bytes32(0), uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function test_zeroTimestamp_reverts() public {
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ZeroTimestamp.selector);
        oracle.publishScore(TARGET, 50, UID_A, 0, uint32(CHAIN_BASE));
    }

    function test_futureTimestamp_reverts() public {
        uint64 future = uint64(block.timestamp) + 1;
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.FutureTimestamp.selector);
        oracle.publishScore(TARGET, 50, UID_A, future, uint32(CHAIN_BASE));
    }

    function test_revertDoesNotMutateState() public {
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(TARGET, 50, UID_A, ts, uint32(CHAIN_BASE));

        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ScoreTooHigh.selector);
        oracle.publishScore(TARGET, 200, UID_B, ts, uint32(CHAIN_BASE));

        ElytraOracle.Score memory s = oracle.scoreOf(TARGET);
        assertEq(s.score,  50,    "score unchanged after revert");
        assertEq(s.easUid, UID_A, "uid unchanged after revert");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_scoreInRange_succeeds(
        uint8   score,
        address tgt,
        uint32  chain,
        bytes32 uid,
        uint64  tsOffset
    ) public {
        score = uint8(bound(uint256(score), 0, 100));
        tsOffset = uint64(bound(uint256(tsOffset), 1, 365 days));
        uint64 ts = uint64(block.timestamp) - tsOffset;
        vm.assume(tgt != address(0));
        vm.assume(uid != bytes32(0));

        vm.prank(ATTESTER);
        oracle.publishScore(tgt, score, uid, ts, chain);

        ElytraOracle.Score memory s = oracle.scoreOf(tgt);
        assertEq(s.score,              score);
        assertEq(s.easUid,             uid);
        assertEq(uint256(s.timestamp), uint256(ts));
        assertEq(uint256(s.chainId),   uint256(chain));
    }

    function testFuzz_scoreOver100_reverts(uint8 score) public {
        vm.assume(score > 100);
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.ScoreTooHigh.selector);
        oracle.publishScore(TARGET, score, UID_A, uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function testFuzz_nonAttester_alwaysReverts(address caller) public {
        vm.assume(caller != ATTESTER);
        vm.prank(caller);
        vm.expectRevert(ElytraOracle.NotAttester.selector);
        oracle.publishScore(TARGET, 50, UID_A, uint64(block.timestamp), uint32(CHAIN_BASE));
    }

    function testFuzz_futureTimestamp_reverts(uint64 future) public {
        vm.assume(future > uint64(block.timestamp));
        vm.prank(ATTESTER);
        vm.expectRevert(ElytraOracle.FutureTimestamp.selector);
        oracle.publishScore(TARGET, 50, UID_A, future, uint32(CHAIN_BASE));
    }
}
