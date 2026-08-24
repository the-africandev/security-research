# CertiK "Billion Dollar AI Auditor" Challenge — Historical Incident Analyses

| | |
|---|---|
| **Engagement** | CertiK Hunt — "Billion Dollar AI Auditor" Challenge (public, ranked) |
| **Date** | 2026-08-05 → 2026-08-19 |
| **Result** | **5th of 19** · 25 incidents claimed · **$162,807,480** in verified loss value scored |
| **Nature of work** | Recovery and root-cause analysis of *already-public historical exploits* — not discovery of new vulnerabilities |
| **Leaderboard** | [hunt.certik.com](https://hunt.certik.com/explore/challenges/ai-auditor-1b) |

> **Scoring note:** the figure above is the total USD lost in the incidents claimed — capped at $50M per incident and decayed by submission position. It is a scoreboard metric, not earnings; prizes were tool credits.

---

## The task

Pick a historical exploit, **recover the contract exactly as it was deployed at the moment of the incident**, scan it, and prove the flagged finding is the bug that was actually used.

The bugs themselves were public. The difficulty was that the contract you can read today is almost never the one that was exploited — protocols patch within hours, proxies get re-pointed, repositories are reverted, block explorers shut down, and some chains never publish source at all. Analysing the patched version proves nothing.

## Write-ups

Three of the twenty-five, chosen because each required a different recovery technique.

| Report | Loss | Bug class | What recovery took |
|---|---|---|---|
| [Thala Labs — `unstake` pays out an unvalidated amount](thala-labs-unstake-unvalidated-withdrawal.md) | ~$25.5M | Value-flow asymmetry (Move / Aptos) | Source stripped on-chain and never published → archival bytecode by ledger version + Revela decompile |
| [Cream Finance — cross-market reentrancy via an ERC-777 hook](cream-finance-august-2021-erc777-reentrancy.md) | ~$18.8M | Reentrancy / CEI violation (EVM) | Proxy re-pointed post-hack → implementation resolved at the incident block |
| [Bonzo Finance / Supra — verifier accepts a zeroed BLS signature](bonzo-finance-supra-verifier-zero-key-bypass.md) | ~$9.05M | Missing input validation (BLS / Hedera) | Verifier hotfixed ~6h later → pre-incident implementation pinned at the exploit block |

**→ [Recovering the Pre-Incident Contract](recovering-pre-incident-contracts.md)** — the cross-cutting methodology: resolving proxies at historical blocks, Sourcify and verified-source mirrors when an explorer is gone, `git checkout <fix>^`, Move archival-bytecode decompilation, and how to prove you are reading the vulnerable version rather than the patched one.

## What the results actually rewarded

Scoring decayed steeply with submission position, so the entire game was being *first* to a given incident. What made a target uncontested was consistently **recovery friction**, not obscurity:

- **Secondary incidents.** Cream's August 2021 reentrancy is a separate event from its famous October 2021 oracle hack; the same pattern held for two Deus Finance incidents a year apart. Each went unclaimed by anyone else.
- **Dead infrastructure.** One Fantom target required a verified-source mirror because ftmscan no longer exists; another required pulling source from GitHub because the on-chain contract was never verified.
- **Chains and dates nobody was scanning.** A five-week-old Hedera incident and a Move/Aptos target both went uncontested while the field re-analysed well-known 2021–22 Ethereum hacks.

Conversely, every target that lost out to duplicates — regardless of how obscure it felt — had a public post-mortem *and* a pinned fix commit. Zero recovery friction meant everyone could reach it.
