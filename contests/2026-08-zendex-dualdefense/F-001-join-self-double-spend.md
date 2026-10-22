# [Critical] `join()` accepts the same note twice — mint unlimited value and drain every vault deposit

| | |
|---|---|
| **Protocol** | Zendex — Noir ZK privacy AMM (shielded vault) |
| **Engagement** | HackenProof DualDefense audit |
| **Date** | 2026-08-31 · paid 2026-09-30 |
| **Severity** | **Critical** (direct theft of end-user funds) |
| **Status** | **Confirmed — paid** · client shipping fix · reported by 58 researchers · report `ZNDXSCDD-147` |
| **Commit / Scope** | `zendex-sc @ b25f3c3` — `ZendexVaultManager.sol`, `TreeOperator.sol`, `circuits/join/src/main.nr` |
| **Report link** | HackenProof submission (disclosed) |

---

## Summary

`ZendexVaultManager.join()` merges two commitments A and B into a new commitment C worth
`amount_a + amount_b`. Nothing — not the Solidity, not the Noir circuit — requires A and B to be
different commitments.

An attacker joins one commitment **with itself**. The circuit proves
`amount_a + amount_b == amount_c` with `amount_a == amount_b == X`, minting a note worth `2X` from a
note worth `X`. Each join doubles the balance. The attacker then withdraws through the ordinary
`withdraw()` path, taking other depositors' assets out of the shared vault.

## Vulnerability Details

Two independent failures. Either fix alone closes the bug.

**1. Contract: both nullifiers are validated before either is consumed.**

```solidity
// contracts/ZendexVaultManager.sol:167-175
_validateNullifier(jp.nullifierA);   // check A
_validateNullifier(jp.nullifierB);   // check B   <-- both checks run...

_validateTree(ipA.depth, ipA.root, ipA.epochId);
_validateTree(ipB.depth, ipB.root, ipB.epochId);

_consume(jp.nullifierA);             // effect A  <-- ...before either effect
_consume(jp.nullifierB);             // effect B
_insert(jp.commitmentC);
```

When `nullifierA == nullifierB`, the check on line 168 reads state that line 173 has not yet
written, so both pass. `TreeOperator.consume()` is a bare, idempotent write:

```solidity
// contracts/TreeOperator.sol:156-158
function consume(uint256 nullifier) external onlyManager {
    nullifierUsed[nullifier] = true;
}
```

There is no `require(jp.nullifierA != jp.nullifierB)` anywhere in `contracts/`.

**2. Circuit: no distinctness constraint.** `circuits/join/src/main.nr` asserts three `u64` range
checks, the sum, two nullifier derivations, three commitment derivations and two tag derivations.
It never asserts `rho_a != rho_b`. Setting `rho_a = rho_b` satisfies every constraint, and the
resulting proof is accepted by the real deployed `JoinVerifier`.

**Why the surrounding guards don't stop it:**

- **Tags** — `tag = H3(epoch_id, commitment, salt)` with a prover-chosen salt. Passing the same
  `ProofData` for both inclusion proofs makes both tag checks hold against one real leaf.
- **Inclusion proofs** — both reference a commitment that genuinely is in the tree: the attacker's
  own deposit. Nothing requires them to reference different leaves.
- **Duplicate-commitment guard** — `commitment_c` uses a fresh `rho_c`, so it is a new leaf.
- **Access control** — `join()` is `external` with no role gate, no pause, no operator.

`join()` is the only entrypoint that consumes two nullifiers, so this is the sole instance of the
pattern.

## Impact

Direct theft of end-user funds, up to the entire `ZendexVault` balance of the chosen asset.
`withdraw()` releases from the pooled balance, so the surplus comes out of other depositors'
principal. `k` joins turn a minimal deposit into `2^k` times its value. Permissionless, no
privileged role, no transaction-ordering dependency.

## Proof of Concept

[`PoC/join-self-double-spend.test.ts`](PoC/join-self-double-spend.test.ts) — place it at
`test/poc/` in the target repo (it imports the project's own helpers via `../../scripts/utils`).

```bash
npx hardhat test test/poc/join-self-double-spend.test.ts
```

1. Attacker deposits 100,000 USDT; a victim deposits 1,000,000 USDT.
2. One inclusion proof is generated for the attacker's commitment `C_A`.
3. A join proof is generated with `C_A` as **both** inputs (`rho_a = rho_b`, `amount_c = 2 × amount_a`).
   The test asserts the deployed verifier accepts it.
4. `join(inclusionProof, inclusionProof, joinProof)` succeeds and inserts `C_C` worth 200,000 USDT.
5. Withdrawing `C_C` pays out 200,000 USDT. The vault is left with exactly the victim's deposit
   minus the attacker's profit.

**Result:**
```
  PoC: join() self-join value inflation
  attacker deposited : 100000.0 USDT
  attacker withdrew  : 200000.0 USDT
  net profit (stolen): 100000.0 USDT
  vault USDT left    : 900000.0
    ✔ mints a note worth 2x the deposit by joining one note with itself, then withdraws the victim's funds
  round 1: note now worth 2.0 USDC
  round 2: note now worth 4.0 USDC
  round 3: note now worth 8.0 USDC
  round 4: note now worth 16.0 USDC
  seeded with 1.0 USDC -> holds 16.0 USDC after 4 joins
    ✔ iterates: 1 unit -> 2 -> 4 -> 8 ... unbounded inflation from a single note

  2 passing
```

## Recommended Mitigation

Fix both layers.

**Contract** — reject duplicated inputs explicitly:

```solidity
require(jp.nullifierA != jp.nullifierB, BaseManager__DuplicateNullifier());
```

**Circuit** — constrain the inputs to be distinct notes so the proof cannot be produced at all:

```noir
assert(rho_a != rho_b);
```

Constraining `rho` is preferable to constraining the nullifiers, because `rho` is what determines
note identity. Review the same shape wherever a handler takes two or more references to tree
state: `split()` and `executeOrders()` are safe only incidentally, with no explicit distinctness
check either.

## References

- Triage ruling: closed Out of scope 2026-09-11 (root cause in the unlisted circuit), reversed to
  Critical 2026-09-25 (exploit executes in listed contracts; a contract-side fix closes it).
