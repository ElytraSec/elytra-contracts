// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ElytraGateRegistry
/// @notice Reference consumer of ElytraOracle. Wraps the oracle with an
///         immutable policy (minScore, reviewCeiling, maxStaleness) and
///         exposes both a non-reverting `decisionOf` and a reverting
///         `requireAllowed` so any Base contract can gate behaviour on
///         a single staticcall.
/// @dev    Not an audit. Not a safety guarantee. The score is a heuristic.
///         The deployer of this registry — not Elytra — chooses the policy.
interface IElytraOracle {
    struct Score {
        uint8   score;
        bytes32 easUid;
        uint64  timestamp;
        uint32  chainId;
    }
    function scoreOf(address target) external view returns (Score memory);
}

contract ElytraGateRegistry {
    // ─── policy (set once, immutable) ──────────────────────────────────────
    IElytraOracle public immutable oracle;
    uint8         public immutable minScore;        // strict floor, < this → BLOCKED
    uint8         public immutable reviewCeiling;   // [minScore, ceiling) → REVIEW; ≥ ceiling → ALLOWED
    uint64        public immutable maxStaleness;    // seconds; older than this → STALE

    enum Decision {
        UNKNOWN,  // never scored (timestamp == 0)
        STALE,    // scored but older than maxStaleness
        BLOCKED,  // fresh, score < minScore
        REVIEW,   // fresh, minScore ≤ score < reviewCeiling
        ALLOWED   // fresh, score ≥ reviewCeiling
    }

    error ZeroOracle();
    error CeilingBelowMin(uint8 minScore, uint8 reviewCeiling);
    error TokenNotAllowed(address token, Decision decision, uint8 score);

    event PolicyDeployed(
        address indexed oracle,
        uint8 minScore,
        uint8 reviewCeiling,
        uint64 maxStaleness
    );

    constructor(
        address _oracle,
        uint8   _minScore,
        uint8   _reviewCeiling,
        uint64  _maxStaleness
    ) {
        if (_oracle == address(0))           revert ZeroOracle();
        if (_reviewCeiling < _minScore)      revert CeilingBelowMin(_minScore, _reviewCeiling);

        oracle        = IElytraOracle(_oracle);
        minScore      = _minScore;
        reviewCeiling = _reviewCeiling;
        maxStaleness  = _maxStaleness;

        emit PolicyDeployed(_oracle, _minScore, _reviewCeiling, _maxStaleness);
    }

    // ─── read API (non-reverting) ──────────────────────────────────────────

    /// @notice Decision + raw score for a token. Native ETH (`address(0)`)
    ///         always returns UNKNOWN — callers should treat as soft-pass.
    function decisionOf(address token) public view returns (Decision, uint8) {
        if (token == address(0)) return (Decision.UNKNOWN, 0);

        IElytraOracle.Score memory s = oracle.scoreOf(token);
        if (s.timestamp == 0) return (Decision.UNKNOWN, 0);

        if (block.timestamp > uint256(s.timestamp) + uint256(maxStaleness)) {
            return (Decision.STALE, s.score);
        }
        if (s.score < minScore)        return (Decision.BLOCKED, s.score);
        if (s.score < reviewCeiling)   return (Decision.REVIEW,  s.score);
        return (Decision.ALLOWED, s.score);
    }

    /// @notice Strict allow: returns true only for ALLOWED. UNKNOWN, STALE,
    ///         BLOCKED, REVIEW all return false. Use when you want hard gating.
    function isAllowed(address token) external view returns (bool) {
        (Decision d, ) = decisionOf(token);
        return d == Decision.ALLOWED;
    }

    /// @notice Lenient allow: returns true unless explicitly BLOCKED.
    ///         UNKNOWN + STALE soft-pass; REVIEW + ALLOWED pass.
    ///         Use when you want to favour availability over strictness.
    function isNotBlocked(address token) external view returns (bool) {
        (Decision d, ) = decisionOf(token);
        return d != Decision.BLOCKED;
    }

    // ─── revert API ────────────────────────────────────────────────────────

    /// @notice Reverts with `TokenNotAllowed` unless decision == ALLOWED.
    ///         Mirrors `isAllowed` semantics but inline-revertable.
    function requireAllowed(address token) external view {
        (Decision d, uint8 score) = decisionOf(token);
        if (d != Decision.ALLOWED) revert TokenNotAllowed(token, d, score);
    }

    /// @notice Reverts only on BLOCKED. UNKNOWN, STALE, REVIEW, ALLOWED pass.
    ///         Use as a one-liner gate in vault deposits, swaps, etc.
    function requireNotBlocked(address token) external view {
        (Decision d, uint8 score) = decisionOf(token);
        if (d == Decision.BLOCKED) revert TokenNotAllowed(token, d, score);
    }
}
