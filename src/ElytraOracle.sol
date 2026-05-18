// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ElytraOracle
/// @notice Onchain index of the latest Elytra security score for any address.
///         Pairs an address (a deployed contract, on any chain) with the most
///         recent score Elytra has published for it, plus the EAS attestation
///         UID that backs the score and a caller-supplied timestamp.
///
///         The attestation is the canonical receipt; this contract is the lookup.
///
/// @dev    Single immutable attester. To rotate, redeploy with a new attester
///         and point dependents at the new address. The attester is trusted to
///         publish honest scores + truthful timestamps — that's the whole point
///         of an oracle. If the key is compromised, redeploy.
contract ElytraOracle {
    // ─────────────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Latest Elytra verdict for a given target address.
    /// @dev    Reader convention: `timestamp == 0` MUST be treated as
    ///         "never scored by Elytra" — never as a passing zero score.
    /// @param score      0..100 — heuristic. NOT a safety guarantee.
    /// @param easUid     UID of the backing EAS attestation on Base mainnet.
    /// @param timestamp  Unix seconds, supplied by the attester (typically the
    ///                   moment of the scan; not necessarily block.timestamp).
    /// @param chainId    Native chain ID of the scanned contract
    ///                   (1 = Ethereum, 8453 = Base, 42161 = Arbitrum, etc.).
    struct Score {
        uint8   score;
        bytes32 easUid;
        uint64  timestamp;
        uint32  chainId;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The only address allowed to publish scores. Set once at deploy.
    address public immutable attester;

    /// @dev Latest score per target. Read via {scoreOf}.
    mapping(address => Score) private latest;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful publish (first write or overwrite).
    ///         Indexes `target` + `chainId` so consumers can subscribe by
    ///         either dimension.
    event Scored(
        address indexed target,
        uint32  indexed chainId,
        uint8           score,
        bytes32         easUid,
        uint64          timestamp
    );

    // ─────────────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────────────

    error NotAttester();
    error ZeroAttester();
    error ZeroTarget();
    error ZeroUid();
    error ZeroTimestamp();
    error FutureTimestamp();
    error ScoreTooHigh();

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @param _attester The wallet that will sign every publish. Must be non-zero.
    constructor(address _attester) {
        if (_attester == address(0)) revert ZeroAttester();
        attester = _attester;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Mutations
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Publish or overwrite the latest score for an address.
    /// @dev    Caller MUST be {attester}. Reverts on:
    ///           - non-attester sender               → NotAttester
    ///           - target == address(0)              → ZeroTarget
    ///           - easUid == bytes32(0)              → ZeroUid
    ///           - timestamp == 0                    → ZeroTimestamp
    ///           - timestamp > block.timestamp       → FutureTimestamp
    ///           - score > 100                       → ScoreTooHigh
    ///
    ///         Idempotent at the contract level: republishing the same values
    ///         succeeds (overwrite is allowed by design — scores update over time).
    ///
    /// @param  target     Address the score is about (any chain).
    /// @param  score      0..100 heuristic score.
    /// @param  easUid     Backing EAS attestation UID (on Base mainnet).
    /// @param  timestamp  Unix seconds at which this score was determined.
    /// @param  chainId    Chain ID of the target.
    function publishScore(
        address target,
        uint8   score,
        bytes32 easUid,
        uint64  timestamp,
        uint32  chainId
    ) external {
        if (msg.sender != attester)         revert NotAttester();
        if (target == address(0))           revert ZeroTarget();
        if (easUid == bytes32(0))           revert ZeroUid();
        if (timestamp == 0)                 revert ZeroTimestamp();
        if (timestamp > uint64(block.timestamp)) revert FutureTimestamp();
        if (score > 100)                    revert ScoreTooHigh();

        latest[target] = Score({
            score:     score,
            easUid:    easUid,
            timestamp: timestamp,
            chainId:   chainId
        });

        emit Scored(target, chainId, score, easUid, timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Reads
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Return the latest Elytra score for an address.
    ///         If never published, returns the zero-valued struct
    ///         (score=0, easUid=bytes32(0), timestamp=0, chainId=0).
    ///         Callers MUST check (timestamp == 0) to detect "never scored"
    ///         — never use score=0 as a passing-zero signal on its own.
    function scoreOf(address target) external view returns (Score memory) {
        return latest[target];
    }
}
