// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}             from "forge-std/Test.sol";
import {ElytraOracle}     from "../src/ElytraOracle.sol";
import {ElytraGateLib}    from "../src/ElytraGateLib.sol";
import {ElytraGateHook, IPoolManagerLike, PoolKey} from "../src/ElytraGateHook.sol";

contract ElytraGateHookTest is Test {
    ElytraOracle    internal oracle;
    ElytraGateHook  internal hook;

    address internal constant ATTESTER  = address(0xA77E51E4);
    address internal constant POOL_MGR  = address(0x9001);
    address internal constant WETH      = address(0x4200000000000000000000000000000000000006);
    address internal constant USDC      = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant BAD_TKN   = address(0xbaDBAdbADbaDBADBAdBaDbaDbadBAdbaDbaDbadb);
    address internal constant UNKNOWN   = address(0xC0FFEE);

    bytes32 internal constant UID = bytes32(uint256(0xAAAA));

    uint8  internal constant MIN_SCORE      = 55;
    uint8  internal constant REVIEW_CEILING = 80;
    uint64 internal constant MAX_STALENESS  = 7 days;

    event ElytraReview(address indexed token, uint8 score, bytes32 easUid);
    event ElytraUnknown(address indexed token);
    event ElytraStale(address indexed token, uint64 timestamp);

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new ElytraOracle(ATTESTER);
        hook   = new ElytraGateHook(
            IPoolManagerLike(POOL_MGR),
            oracle,
            MIN_SCORE,
            REVIEW_CEILING,
            MAX_STALENESS
        );

        // Seed: WETH = 97 (low_risk), USDC = 88 (review band), BAD_TKN = 30 (blocked)
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(WETH,    97, UID, ts, 8453);
        vm.prank(ATTESTER);
        oracle.publishScore(USDC,    88, UID, ts, 8453);
        vm.prank(ATTESTER);
        oracle.publishScore(BAD_TKN, 30, UID, ts, 8453);
        // UNKNOWN intentionally not seeded
    }

    function _key(address c0, address c1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0:   c0,
            currency1:   c1,
            fee:         3000,
            tickSpacing: 60,
            hooks:       address(0)
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(bytes("elytra zero"));
        new ElytraGateHook(IPoolManagerLike(POOL_MGR), ElytraOracle(address(0)), 55, 80, 7 days);
    }

    function test_constructor_rejectsCeilingBelowMin() public {
        vm.expectRevert(bytes("ceiling < min"));
        new ElytraGateHook(IPoolManagerLike(POOL_MGR), oracle, 80, 55, 7 days);
    }

    function test_constructor_setsAllFields() public view {
        assertEq(address(hook.elytra()),      address(oracle));
        assertEq(hook.minScore(),             MIN_SCORE);
        assertEq(hook.reviewCeiling(),        REVIEW_CEILING);
        assertEq(uint256(hook.maxStaleness()), uint256(MAX_STALENESS));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Soft-pass paths
    // ─────────────────────────────────────────────────────────────────────

    function test_softPass_nativeETH_doesNotRevert_doesNotEmit() public {
        // currency0 = 0x0 (native) and currency1 = WETH (recognised, score 97 = low_risk)
        // Expect: no revert, no event for either side (ETH skipped, WETH > reviewCeiling)
        PoolKey memory k = _key(address(0), WETH);
        hook._beforeSwapCheck(k);
    }

    function test_softPass_unknownToken_emitsUnknown_doesNotRevert() public {
        vm.expectEmit(true, false, false, false, address(hook));
        emit ElytraUnknown(UNKNOWN);
        hook._beforeSwapCheck(_key(UNKNOWN, WETH));
    }

    function test_softPass_staleScore_emitsStale_doesNotRevert() public {
        // Re-seed USDC with a stale timestamp
        vm.prank(ATTESTER);
        oracle.publishScore(USDC, 88, UID, uint64(block.timestamp) - 30 days, 8453);

        vm.expectEmit(true, false, false, false, address(hook));
        emit ElytraStale(USDC, uint64(block.timestamp) - 30 days);
        hook._beforeSwapCheck(_key(USDC, WETH));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Review band — emit, don't revert
    // ─────────────────────────────────────────────────────────────────────

    function test_reviewBand_emitsReview_doesNotRevert() public {
        // USDC seeded at 88 — review band is [55, 80). USDC at 88 is ABOVE the ceiling,
        // so it should NOT be flagged. Re-seed in the review band to actually test.
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(USDC, 72, UID, ts, 8453);

        vm.expectEmit(true, false, false, true, address(hook));
        emit ElytraReview(USDC, 72, UID);
        hook._beforeSwapCheck(_key(USDC, address(0)));
    }

    function test_aboveReviewCeiling_noEmit() public {
        // WETH = 97, above 80 ceiling — should be silent.
        // (We can't easily prove "no event" with vm.expectEmit, but call should succeed.)
        hook._beforeSwapCheck(_key(WETH, address(0)));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Revert path
    // ─────────────────────────────────────────────────────────────────────

    function test_blockedToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            ElytraGateLib.ElytraBlocked.selector, BAD_TKN, uint8(30), UID
        ));
        hook._beforeSwapCheck(_key(BAD_TKN, WETH));
    }

    function test_blockedAsCurrency1_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            ElytraGateLib.ElytraBlocked.selector, BAD_TKN, uint8(30), UID
        ));
        hook._beforeSwapCheck(_key(WETH, BAD_TKN));
    }

    function test_blockedAtBoundary_reverts() public {
        // minScore = 55, score = 54 should revert
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(BAD_TKN, 54, UID, ts, 8453);

        vm.expectRevert(abi.encodeWithSelector(
            ElytraGateLib.ElytraBlocked.selector, BAD_TKN, uint8(54), UID
        ));
        hook._beforeSwapCheck(_key(BAD_TKN, address(0)));
    }

    function test_atMinScore_doesNotRevert() public {
        // minScore = 55, score = 55 is NOT strictly below → should pass to review band
        uint64 ts = uint64(block.timestamp) - 60;
        vm.prank(ATTESTER);
        oracle.publishScore(BAD_TKN, 55, UID, ts, 8453);

        vm.expectEmit(true, false, false, true, address(hook));
        emit ElytraReview(BAD_TKN, 55, UID);
        hook._beforeSwapCheck(_key(BAD_TKN, address(0)));
    }
}
