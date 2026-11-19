# Report: Circle Gateway batch shortfall → unbacked balance → vault drain

**Target:** `circlefin/evm-gateway-contracts` (`GatewayWallet` / `Batches`)  
**Date:** 2026-09-21  
**Method:** local Foundry (Anvil, `deal()`). Not mainnet.

## 1. Finding

`MustNetToZero` is the wrong invariant.

It enforces “signed deltas sum to zero.” It does not enforce “USDC credited equals USDC actually taken from accounts.” Combined with saturating debit (`_reduceBalance` never reverts), a batch can credit an attacker without a matching source of funds.

## 2. Code path

**Credit:** `_increaseAvailableBalance` — full `delta.value`.  
**Debit:** `_reduceBalance` in `Balances.sol` — take `min(requested, available+withdrawing)`, then:

```solidity
emit InsufficientBalance(...);
// keep going — no revert
```

**Guard:** after the loop, `if (totalDelta != 0) revert MustNetToZero`.  
`totalDelta` is the sum of the **requested** signed integers.

| Check | Batch `[-N underfunded, +N attacker]` |
|-------|----------------------------------------|
| Nominal net | `-N + N = 0` → pass |
| Actual debit from underfunded | `min(N, 0) = 0` |
| Actual credit to attacker | `+N` |
| Vault ERC20 | unchanged |

Ledger is now `+N` with no deposit.

## 3. Official tests already encode the inflation

`test/wallet/Batches.t.sol` → `testSubmitBatchInsufficientBalance`:

- Account 0 holds `1_000_000_000` (including 50 withdrawing).
- Batch `[-1_000_000_001, +1_000_000_001]`.
- Expects `InsufficientBalance` **and** `BatchProcessed`.
- Asserts account 1 balance `2_000_000_001`.

That is a **+1** ledger inflation, treated as expected behavior.

`Burns.sol` (~531): *if the full amount could not be deducted, emit and continue / burn what we can.*  
`Batches` debit comments point at the same semantics.

This PoC only adds the missing step: **turn the phantom balance into a withdrawal**.

## 4. Tests in this repo

File: `test/poc/BatchShortfallInflation.t.sol`

1. **Inflate** — N = 1000 USDC (6 decimals). Attacker `availableBalance == N`, vault custody still `N` (honest deposit only).
2. **Drain** — `initiateWithdrawal` → `vm.roll(delay+1)` → `withdraw`. Attacker wallet = N, vault = 0, honest ledger still shows N (insolvent).
3. **Repeat** — three new `batchId`s, +100e6 each.

How to run: see [README.md](README.md).

## 5. What this is not

- Not “anyone can drain Gateway on mainnet.”
- Not a missing access-control check on `withdraw` (withdraw is meant to be user-initiated after delay).
- Not a CCTP / attestation dual-spend proof. That would need a second PoC on the burn → mint path.

The privileged step is **getting `batchSigner` to sign a stale or malicious net-zero batch** (buggy off-chain matcher, compromised signer, or operator error). The chain will settle it.

## 6. Suggested fix

1. Revert the batch if any debit shortfalls.
2. Net-zero on **realized** amounts, or pre-check `balance >= debit`.
3. Alert/pause on `InsufficientBalance` in production.

## 7. Pointers in upstream

- `src/modules/wallet/Batches.sol` — `_processBatch`
- `src/modules/wallet/Balances.sol` — `_reduceBalance`
- `src/modules/wallet/Burns.sol` — shortfall comment
- `test/wallet/Batches.t.sol` — `testSubmitBatchInsufficientBalance`
