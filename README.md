# Circle Gateway — `MustNetToZero` checks the nominal net, not the real debit

Local Foundry research against [`circlefin/evm-gateway-contracts`](https://github.com/circlefin/evm-gateway-contracts).  
**Anvil only.** Tests use `deal()`. No mainnet funds, no production keys.

| | |
|---|---|
| **Proven** | A signed batch `[-N` empty account, `+N` attacker] passes the on-chain guard, mints unbacked `availableBalance`, and withdraws mock USDC from the vault. |
| **Not claimed** | An unprivileged user can submit that batch. Submission still needs `batchSigner`. |

If you only read this file: the bug is an **accounting invariant**, not a missing `onlyOwner`. Once a bad batch is signed, the chain will not stop it.

---

## Root cause

In `Batches._processBatch`:

1. Credits always apply the full delta.
2. Debits call `_reduceBalance`, which **saturates at zero** and emits `InsufficientBalance` — then **continues**.
3. After the loop, `MustNetToZero` checks `sum(signed deltas) == 0`. That is the **nominal** `int256` net, not “amount actually taken from accounts”.

So this batch is accepted:

```
underfunded:  -N     (balance 0 → actually deduct 0)
attacker:     +N     (credited in full)
nominal net:   0     → guard passes
vault ERC20:  unchanged
```

Attacker now has `availableBalance += N` with no matching deposit. `initiateWithdrawal` → wait delay → `withdraw` moves real mock USDC out. Honest depositors still show a ledger balance against an empty vault.

Circle’s own `testSubmitBatchInsufficientBalance` already expects this inflation (debit 1e9+1 from a 1e9 account, credit 1e9+1). The official suite treats shortfall-and-continue as intended. This PoC shows the **withdraw path** after that inflation.

`Burns.sol` documents the same policy: *if the full amount could not be deducted, emit and continue / burn what we can.*

---

## Reproduce (3/3 tests)

Needs [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/circlefin/evm-gateway-contracts.git
cd evm-gateway-contracts

# drop this repo’s test into their tree
mkdir -p test/poc
curl -fsSL -o test/poc/BatchShortfallInflation.t.sol \
  https://raw.githubusercontent.com/Flutedsi/gateway-batch-shortfall-poc/main/test/poc/BatchShortfallInflation.t.sol

forge test --match-path test/poc/BatchShortfallInflation.t.sol -vv
```

| Test | What it shows |
|------|----------------|
| `test_poc_inflateAvailableBalance_N1000` | Phantom `+1000e6` on attacker; vault custody unchanged |
| `test_poc_drainVaultViaWithdrawal_N1000` | After delay, attacker receives 1000 mock USDC; vault = 0; honest ledger still shows 1000 |
| `test_poc_repeatableNewBatchId` | New `batchId` can inflate again |

Local run (2026-09-21): **3/3 PASS**.

---

## Threat model (split on purpose)

| Layer | Result |
|-------|--------|
| On-chain settlement | Will **not** revert a net-zero batch whose real debits are smaller than credits |
| Who can submit | Only an address in `batchSigner` (or whoever can make that key sign) |
| Cross-chain mint | Not proven here. If unbacked balance can later enter a burn → attestation → mint path, that is a separate claim |

This is the same class of bug as “the matcher nets to zero on paper, the vault does not.”

---

## Fix direction

1. Debit shortfall should **revert the whole batch** (or be atomic). Do not `emit` and continue.
2. The net-zero guard should compare **actual deducted** vs **actual credited**, or `require(balance >= amount)` before debit.
3. Treat any production `InsufficientBalance` as an incident, not a log line.

---

## Repo layout

```
README.md                                      ← you are here
REPORT.md                                      ← longer write-up + official-test citation
test/poc/BatchShortfallInflation.t.sol         ← the only original code
```

This repository does **not** vendor Circle’s tree, `lib/`, or any red-team wallets.

Author: Zhao Yonghao ([@Flutedsi](https://github.com/Flutedsi)).
