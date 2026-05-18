// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ElytraOracle} from "./ElytraOracle.sol";

/// @title  ElytraGateLib
/// @notice Pure library functions hook authors can call inside their own
///         `beforeSwap` (or any other gating path) to consult the Elytra score
///         for an address.
///
///         Elytra does NOT own swap policy here. The caller decides:
///           - which oracle address to read from
///           - what minScore is too low
///           - what maxStaleness is too old
///           - what to do on "never scored" (soft-pass / revert / log)
///
///         This library only provides the read + the standard checks.
library ElytraGateLib {
    error ElytraBlocked(address token, uint8 score, bytes32 easUid);

    /// @notice Result describing the policy decision for a single token.
    /// @param   recognised  True if the oracle has ever scored this token.
    /// @param   fresh       True if the stored timestamp is within maxStaleness.
    /// @param   blocked     True if recognised + fresh + score < minScore.
    /// @param   review      True if recognised + fresh + minScore <= score < reviewCeiling.
    /// @param   score       The score returned by the oracle (0 when not recognised).
    /// @param   easUid      The EAS attestation UID backing the score.
    struct Outcome {
        bool    recognised;
        bool    fresh;
        bool    blocked;
        bool    review;
        uint8   score;
        bytes32 easUid;
    }

    /// @notice Inspect a token's Elytra score against a policy without reverting.
    /// @param  oracle          The deployed `ElytraOracle` address.
    /// @param  token           The token / contract to score.
    /// @param  minScore        Scores strictly below this are `blocked` (e.g. 55).
    /// @param  reviewCeiling   Scores below this (and >= minScore) are `review` (e.g. 80).
    /// @param  maxStaleness    Max age in seconds for a score to be considered fresh.
    function inspect(
        ElytraOracle oracle,
        address      token,
        uint8        minScore,
        uint8        reviewCeiling,
        uint64       maxStaleness
    ) internal view returns (Outcome memory out) {
        if (token == address(0)) return out; // native ETH / zero — caller decides

        ElytraOracle.Score memory s = oracle.scoreOf(token);
        if (s.timestamp == 0) return out;    // never scored — recognised=false

        out.recognised = true;
        out.score      = s.score;
        out.easUid     = s.easUid;
        out.fresh      = (block.timestamp - s.timestamp) <= maxStaleness;

        if (!out.fresh) return out;          // stale — caller decides if treated as unknown
        out.blocked = (s.score < minScore);
        out.review  = (!out.blocked && s.score < reviewCeiling);
    }

    /// @notice Revert if `inspect` returns `blocked = true`. No-op otherwise.
    ///         The recommended one-line check for hooks that want simple gating.
    function requireNotBlocked(
        ElytraOracle oracle,
        address      token,
        uint8        minScore,
        uint64       maxStaleness
    ) internal view {
        if (token == address(0)) return;
        ElytraOracle.Score memory s = oracle.scoreOf(token);
        if (s.timestamp == 0)                                       return; // soft pass
        if ((block.timestamp - s.timestamp) > maxStaleness)         return; // stale → soft pass
        if (s.score < minScore) revert ElytraBlocked(token, s.score, s.easUid);
    }
}
