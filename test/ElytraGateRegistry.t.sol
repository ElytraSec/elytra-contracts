// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ElytraGateRegistry} from "../src/ElytraGateRegistry.sol";
import {ElytraOracle}       from "../src/ElytraOracle.sol";

contract ElytraGateRegistryTest is Test {
    ElytraOracle        oracle;
    ElytraGateRegistry  registry;

    address constant ATTESTER = address(0xA11CE);

    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ROUTER  = address(0x9001);   // imagine an upgradeable router
    address constant BAD_TKN = 0xbaDBAdbADbaDBADBAdBaDbaDbadBAdbaDbaDbadb;
    address constant UNKNOWN = address(0xC0FFEE);

    bytes32 constant UID = bytes32(uint256(0xAAAA));

    uint8  constant MIN_SCORE       = 55;
    uint8  constant REVIEW_CEILING  = 80;
    uint64 constant MAX_STALENESS   = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle   = new ElytraOracle(ATTESTER);
        registry = new ElytraGateRegistry(address(oracle), MIN_SCORE, REVIEW_CEILING, MAX_STALENESS);

        // Seed scores: WETH ALLOWED, USDC ALLOWED, ROUTER REVIEW, BAD BLOCKED, UNKNOWN untouched
        vm.startPrank(ATTESTER);
        oracle.publishScore(WETH,    97, UID, uint64(block.timestamp), 8453);
        oracle.publishScore(USDC,    88, UID, uint64(block.timestamp), 8453);
        oracle.publishScore(ROUTER,  61, UID, uint64(block.timestamp), 8453);
        oracle.publishScore(BAD_TKN, 30, UID, uint64(block.timestamp), 8453);
        vm.stopPrank();
    }

    // ─── constructor ───────────────────────────────────────────────────────

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(ElytraGateRegistry.ZeroOracle.selector);
        new ElytraGateRegistry(address(0), 55, 80, 7 days);
    }

    function test_constructor_rejectsCeilingBelowMin() public {
        vm.expectRevert(abi.encodeWithSelector(ElytraGateRegistry.CeilingBelowMin.selector, uint8(80), uint8(60)));
        new ElytraGateRegistry(address(oracle), 80, 60, 7 days);
    }

    function test_constructor_setsAllFields() public view {
        assertEq(address(registry.oracle()),  address(oracle));
        assertEq(registry.minScore(),         MIN_SCORE);
        assertEq(registry.reviewCeiling(),    REVIEW_CEILING);
        assertEq(registry.maxStaleness(),     MAX_STALENESS);
    }

    // ─── decisionOf classification ─────────────────────────────────────────

    function test_decisionOf_native_isUnknown() public view {
        (ElytraGateRegistry.Decision d, uint8 score) = registry.decisionOf(address(0));
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.UNKNOWN));
        assertEq(score, 0);
    }

    function test_decisionOf_unscored_isUnknown() public view {
        (ElytraGateRegistry.Decision d, uint8 score) = registry.decisionOf(UNKNOWN);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.UNKNOWN));
        assertEq(score, 0);
    }

    function test_decisionOf_blocked() public view {
        (ElytraGateRegistry.Decision d, uint8 score) = registry.decisionOf(BAD_TKN);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.BLOCKED));
        assertEq(score, 30);
    }

    function test_decisionOf_review() public view {
        (ElytraGateRegistry.Decision d, uint8 score) = registry.decisionOf(ROUTER);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.REVIEW));
        assertEq(score, 61);
    }

    function test_decisionOf_allowed_atCeiling() public {
        address tok = address(0x123);
        vm.prank(ATTESTER);
        oracle.publishScore(tok, REVIEW_CEILING, UID, uint64(block.timestamp), 8453);
        (ElytraGateRegistry.Decision d, ) = registry.decisionOf(tok);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.ALLOWED));
    }

    function test_decisionOf_review_atMinScore() public {
        address tok = address(0x124);
        vm.prank(ATTESTER);
        oracle.publishScore(tok, MIN_SCORE, UID, uint64(block.timestamp), 8453);
        (ElytraGateRegistry.Decision d, ) = registry.decisionOf(tok);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.REVIEW));
    }

    function test_decisionOf_blocked_belowMinByOne() public {
        address tok = address(0x125);
        vm.prank(ATTESTER);
        oracle.publishScore(tok, MIN_SCORE - 1, UID, uint64(block.timestamp), 8453);
        (ElytraGateRegistry.Decision d, ) = registry.decisionOf(tok);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.BLOCKED));
    }

    function test_decisionOf_stale() public {
        vm.warp(block.timestamp + 8 days);
        (ElytraGateRegistry.Decision d, uint8 score) = registry.decisionOf(USDC);
        assertEq(uint256(d), uint256(ElytraGateRegistry.Decision.STALE));
        assertEq(score, 88);
    }

    // ─── isAllowed (strict) ────────────────────────────────────────────────

    function test_isAllowed_strict_onlyAllowed() public view {
        assertTrue (registry.isAllowed(WETH));
        assertTrue (registry.isAllowed(USDC));
        assertFalse(registry.isAllowed(ROUTER));   // REVIEW
        assertFalse(registry.isAllowed(BAD_TKN));  // BLOCKED
        assertFalse(registry.isAllowed(UNKNOWN));  // UNKNOWN
        assertFalse(registry.isAllowed(address(0))); // native
    }

    // ─── isNotBlocked (lenient) ────────────────────────────────────────────

    function test_isNotBlocked_lenient_passesExceptBlocked() public view {
        assertTrue (registry.isNotBlocked(WETH));      // ALLOWED
        assertTrue (registry.isNotBlocked(USDC));      // ALLOWED
        assertTrue (registry.isNotBlocked(ROUTER));    // REVIEW
        assertFalse(registry.isNotBlocked(BAD_TKN));   // BLOCKED
        assertTrue (registry.isNotBlocked(UNKNOWN));   // UNKNOWN soft-pass
        assertTrue (registry.isNotBlocked(address(0))); // native soft-pass
    }

    // ─── requireAllowed reverts ────────────────────────────────────────────

    function test_requireAllowed_passes_forAllowed() public view {
        registry.requireAllowed(USDC);
    }

    function test_requireAllowed_reverts_forReview() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ElytraGateRegistry.TokenNotAllowed.selector,
                ROUTER,
                ElytraGateRegistry.Decision.REVIEW,
                uint8(61)
            )
        );
        registry.requireAllowed(ROUTER);
    }

    function test_requireAllowed_reverts_forBlocked() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ElytraGateRegistry.TokenNotAllowed.selector,
                BAD_TKN,
                ElytraGateRegistry.Decision.BLOCKED,
                uint8(30)
            )
        );
        registry.requireAllowed(BAD_TKN);
    }

    function test_requireAllowed_reverts_forUnknown() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ElytraGateRegistry.TokenNotAllowed.selector,
                UNKNOWN,
                ElytraGateRegistry.Decision.UNKNOWN,
                uint8(0)
            )
        );
        registry.requireAllowed(UNKNOWN);
    }

    // ─── requireNotBlocked reverts ─────────────────────────────────────────

    function test_requireNotBlocked_passes_forAllowed() public view {
        registry.requireNotBlocked(USDC);
    }

    function test_requireNotBlocked_passes_forReview() public view {
        registry.requireNotBlocked(ROUTER);
    }

    function test_requireNotBlocked_passes_forUnknown() public view {
        registry.requireNotBlocked(UNKNOWN);
    }

    function test_requireNotBlocked_reverts_onBlocked() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ElytraGateRegistry.TokenNotAllowed.selector,
                BAD_TKN,
                ElytraGateRegistry.Decision.BLOCKED,
                uint8(30)
            )
        );
        registry.requireNotBlocked(BAD_TKN);
    }
}
