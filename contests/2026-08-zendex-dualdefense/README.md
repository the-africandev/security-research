# Zendex — HackenProof DualDefense audit (2026-08)

| | |
|---|---|
| **Protocol** | Zendex — Noir ZK privacy AMM: shielded vault, private swaps, limit orders |
| **Engagement** | HackenProof DualDefense audit (Critical-only, shared pool) |
| **Scope** | `hackenproof-public/zendex-sc @ b25f3c3` — 17 listed Solidity files |
| **Result** | **1 confirmed Critical — paid** |

## Findings

| # | Finding | Submitted | Final | Status |
|---|---------|-----------|-------|--------|
| F-001 | [`join()` accepts the same note twice — unlimited value minting, full vault drain](F-001-join-self-double-spend.md) | Critical | **Critical** | **Confirmed — paid** · client shipping fix |

The PoC in [`PoC/`](PoC/) runs against the project's own Hardhat harness and generates **real**
Noir/UltraHonk proofs — no verifier is mocked and no in-scope contract is modified.

A second submission, a quadratic-gas `TreeOperator.insert()` that bricks the order book, was closed
as a known issue: it duplicated a finding from the parallel Hacken audit. Fair ruling, not contested.

## Note on scope

F-001 was first closed **Out of scope**. The missing distinctness constraint lives in
`circuits/join/src/main.nr`, which was not one of the 17 listed Solidity files, and the audit team's
position was that input distinctness is a property of the proof witness.

Two weeks later the closure was withdrawn and the report triaged at Critical: the exploit executes
in `ZendexVaultManager` and `TreeOperator`, both listed, and a contract-side check alone closes it.
The client is shipping both fixes.

The lesson: in a ZK system the contract and the circuit are one security boundary. A bug in the
seam between them belongs to whichever side can enforce the invariant, and the writeup should show
that the listed side can.

## Note on contest economics

The finding was reported by **58 researchers**. The $2,000 pool was split across two unique
Criticals, then across duplicate reporters, for **$17.24** each — the same pattern recorded in
[TipRun](../2026-06-tiprun/README.md#note-on-contest-economics). I hunted it anyway because the code
was fresh, unaudited and novel, which is where real Criticals live. The thesis held; the venue
just doesn't pay for it.
