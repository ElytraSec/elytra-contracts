# @elytrasec/contracts

Solidity contracts for the Elytra security agent. Foundry project.

Currently contains:

- **`ElytraOracle.sol`** — onchain index of the latest Elytra security score
  for any address. A convenience lookup that points to the canonical EAS
  attestation backing the score.

## What `ElytraOracle` IS

- A read-cheap mapping `(address) → (score, easUid, timestamp, chainId)`
  any Base contract can query in a single `staticcall`.
- A write-restricted index. Only the immutable `attester` wallet (the Elytra
  agent's signer, `0x3bfb…1fc2` on Base mainnet) can `publishScore`.
- A pointer back to the EAS attestation that produced the score, so anyone
  reading the oracle can verify the underlying evidence on
  [base.easscan.org](https://base.easscan.org).
- An overwriting index: each `publishScore` replaces the previous score for
  that address. History lives on EAS, not here.

## What `ElytraOracle` is NOT

- **Not a safety guarantee.** A non-zero score does not mean an address is
  safe to interact with. The score is a heuristic.
- **Not an approval.** Elytra does not endorse, certify, or audit any
  contract published in this index.
- **Not an audit.** Reading from `ElytraOracle` is not a substitute for a
  human security audit.
- **Not a price feed.** This is a code-scan signal, not a market signal.
- **Not real-time.** The score is only as fresh as the most recent paid
  Elytra scan of that address.
- **Not append-only.** Older scores are overwritten in place. For the
  durable history, query EAS by recipient address.

## Conservative claims (only use these)

✅ "Latest Elytra score for this address, published onchain on Base"
✅ "Onchain pointer to the EAS attestation that backs the latest score"
✅ "Updated when our scanner re-runs and detects a material change"
✅ "Restricted writer: only the Elytra agent wallet can publish scores"

❌ Do not write: "safe", "verified safe", "approved", "audited",
   "Elytra-certified", "real-time", "prevents hacks".

## Contract surface

```solidity
struct Score {
    uint8   score;     // 0..100 heuristic
    bytes32 easUid;    // backing EAS attestation UID on Base
    uint64  timestamp; // block.timestamp of the publish
    uint32  chainId;   // chain ID of the scanned address
}

address public immutable attester;

function publishScore(address target, uint32 chainId, uint8 score, bytes32 easUid) external;
function scoreOf(address target) external view returns (Score memory);

event Scored(address indexed target, uint32 indexed chainId, uint8 score, bytes32 easUid);

error NotAttester();
error ZeroAttester();
error ZeroTarget();
error ZeroUid();
error ScoreTooHigh();
```

Caller convention for readers: `if (scoreOf(addr).timestamp == 0)` →
**never scanned by Elytra**, not "score = 0".

## Layout / storage

- 1 slot for the immutable `attester` (not stored, baked into code).
- `mapping(address => Score)` — each populated entry occupies **3 storage
  slots** per the declared struct field order
  (`uint8` cannot pack with `bytes32`; `uint64+uint32` packs into one slot).
- A future v1.1 could reorder to (`bytes32 easUid, uint8 score, uint64
  timestamp, uint32 chainId`) to compress to 2 slots, saving ~22.1k gas on
  first write and ~5k on overwrite. Deferred — the current cost is already
  sub-cent on Base.

## Local development (once Foundry is installed)

These contracts compile and test under [Foundry](https://book.getfoundry.sh).
Install Foundry separately — this package does not pin or fetch it.

```bash
# from packages/contracts/
forge install foundry-rs/forge-std --no-commit
forge build
forge test
forge test --gas-report
forge fmt --check
```

## Expected commands once Foundry is installed

```bash
# inside packages/contracts/

# Run every test (constructor, happy path, reverts, boundary, fuzz)
forge test -vv

# Same plus a gas-cost table for ElytraOracle
forge test --gas-report

# Snapshot gas to .gas-snapshot for diff review on future PRs
forge snapshot

# Format Solidity sources
forge fmt
```

## Deployment notes — DO NOT DEPLOY FROM THIS README

Deployment is intentionally not automated here. Follow the deploy runbook
when you're ready, and only after:

1. `forge test --gas-report` passes locally
2. A deploy to **Base Sepolia** (chain 84532) confirms real gas numbers
3. Mainnet target gas at the current Base fee is within the budget set
   in the Oracle Phase 2 economics doc

Mainnet deploy (Base 8453):

```bash
# Constructor arg: the existing Elytra agent wallet, the same one that
# signs EAS attestations (X402_WALLET_ADDRESS in packages/web/.env).
forge create \
  --rpc-url base \
  --private-key "$X402_WALLET_KEY" \
  --constructor-args "$X402_WALLET_ADDRESS" \
  src/ElytraOracle.sol:ElytraOracle

# Then verify on Basescan via Etherscan V2:
forge verify-contract \
  --chain base \
  --constructor-args $(cast abi-encode "constructor(address)" "$X402_WALLET_ADDRESS") \
  <DEPLOYED_ADDRESS> \
  src/ElytraOracle.sol:ElytraOracle
```

Save the deployed address as `ELYTRA_ORACLE_ADDRESS` in
`/home/ubuntu/elytrasec/packages/web/.env`. The web app reads it from there.

## Versioning

- v1 (current): single immutable attester, overwriting index, no batching,
  no rotation, no history. Score-change-only publishing logic lives in the
  web app, not the contract — keeping the contract minimal and auditable.

## Audit status

- **Not audited.** Internal review only. Suitable for early-launch use given
  the small surface and the limited damage radius of a writer key
  compromise (attacker could publish bogus scores; cannot drain funds, mint
  tokens, or escalate privileges; readers can fall back to the underlying
  EAS attestation).

## License

MIT.
