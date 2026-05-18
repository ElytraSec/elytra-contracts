// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ElytraOracle}   from "./ElytraOracle.sol";
import {ElytraGateLib}  from "./ElytraGateLib.sol";

/// @dev Minimal v4-shaped interfaces so this file compiles standalone in our
///      `packages/contracts/` Foundry setup (which doesn't ship v4-core /
///      v4-periphery as deps). Production users should:
///        1. Install `Uniswap/v4-core` + `Uniswap/v4-periphery` via `forge install`
///        2. Replace the inline `IPoolManagerLike` + `PoolKey` + `IHooks` shims
///           below with the canonical imports.
///        3. Inherit from `BaseHook` and remove the local stubs.
///
///      The logic of the `_beforeSwap` body is the only thing you actually need.
interface IPoolManagerLike {}

struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

/// @title  ElytraGateHook (reference implementation)
/// @notice A reference Uniswap v4 hook that consults Elytra before each swap
///         and reverts the swap when the score is below a deployer-chosen
///         threshold.
///
///         This contract is OPINIONATED at deploy time, not at protocol level:
///         the deployer picks `minScore`, `reviewCeiling`, and `maxStaleness`,
///         AND decides whether to revert on `blocked` or emit-only on `review`.
///         Elytra publishes the data; the hook deployer owns the policy.
///
///         Knobs:
///           - `minScore`       — strictly-below = revert (default 55, i.e. block on D/F grade)
///           - `reviewCeiling`  — below this and >= minScore = emit a review event (default 80)
///           - `maxStaleness`   — older than this = soft-pass as if unknown (default 7 days)
///
///         Safety:
///           - Tokens the oracle has never scored = SOFT PASS (do not block fresh-deploy tokens
///             from trading just because Elytra hasn't seen them yet).
///           - Stale entries = SOFT PASS (same reason — don't trap pools when our keeper lags).
///           - Native ETH (currency 0x0) = SOFT PASS by convention.
///
/// @dev    DO NOT deploy this to a real pool without thinking through:
///           (a) the FP rate for canonical contracts at your chosen `minScore`
///               (Aerodrome Router scored D, Universal Router scored F — revert
///                at >55 will block legitimate routes)
///           (b) how stalled-keeper behaviour affects your pool's UX
///           (c) which addresses you want to allowlist around the score check.
contract ElytraGateHook {
    using ElytraGateLib for ElytraOracle;

    ElytraOracle public immutable elytra;
    IPoolManagerLike public immutable poolManager;

    uint8  public immutable minScore;        // strictly-below = revert
    uint8  public immutable reviewCeiling;   // below this + >= minScore = emit review event
    uint64 public immutable maxStaleness;    // seconds

    /// @notice Emitted (not reverted) for tokens in the review band.
    event ElytraReview(address indexed token, uint8 score, bytes32 easUid);

    /// @notice Emitted for tokens the oracle has never scored.
    event ElytraUnknown(address indexed token);

    /// @notice Emitted for tokens whose score is older than maxStaleness.
    event ElytraStale(address indexed token, uint64 timestamp);

    /// @param _poolManager     v4 PoolManager singleton this hook attaches to.
    /// @param _elytra          Deployed ElytraOracle.
    /// @param _minScore        Strictly-below revert threshold. Default rec: 55.
    /// @param _reviewCeiling   Below-this-and->=minScore review band. Default rec: 80.
    /// @param _maxStaleness    Max age (sec) for a score to be considered fresh. Default rec: 7 days.
    constructor(
        IPoolManagerLike _poolManager,
        ElytraOracle     _elytra,
        uint8            _minScore,
        uint8            _reviewCeiling,
        uint64           _maxStaleness
    ) {
        require(address(_elytra) != address(0), "elytra zero");
        require(_reviewCeiling >= _minScore,    "ceiling < min");
        poolManager   = _poolManager;
        elytra        = _elytra;
        minScore      = _minScore;
        reviewCeiling = _reviewCeiling;
        maxStaleness  = _maxStaleness;
    }

    /// @notice Mirror of the v4 `beforeSwap` selector signature. In production,
    ///         override the BaseHook hook callback. Here we expose the same
    ///         logic as a plain `external` function so tests can call it.
    ///
    ///         The `poolManager`-sender check is intentionally REMOVED from this
    ///         reference because we don't pull v4-core into the standalone build.
    ///         When inheriting from `BaseHook`, the override automatically
    ///         enforces `msg.sender == poolManager`.
    function _beforeSwapCheck(PoolKey calldata key) external {
        _check(key.currency0);
        _check(key.currency1);
    }

    /// @dev Internal: inspect one token, revert on `blocked`, emit on `review` / `unknown` / `stale`.
    function _check(address token) internal {
        if (token == address(0)) return;

        ElytraGateLib.Outcome memory o = ElytraGateLib.inspect(
            elytra, token, minScore, reviewCeiling, maxStaleness
        );

        if (!o.recognised) { emit ElytraUnknown(token);             return; }
        if (!o.fresh)      { emit ElytraStale(token, _ts(token));   return; }
        if (o.blocked)     { revert ElytraGateLib.ElytraBlocked(token, o.score, o.easUid); }
        if (o.review)      { emit ElytraReview(token, o.score, o.easUid);                  }
    }

    function _ts(address token) internal view returns (uint64) {
        return elytra.scoreOf(token).timestamp;
    }
}
