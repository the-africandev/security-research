# TipRun — HackenProof audit contest (2026-06)

| | |
|---|---|
| **Protocol** | TipRun — perpetuals clearing: off-chain order matching, on-chain custody and settlement |
| **Engagement** | HackenProof (audit contest) |
| **Scope** | `hackenproof-public/tiprun-contracts @ d5d4d2a` — `src/**/*.sol` |
| **Result** | **2 confirmed findings — 1 Critical, 1 High — both fixed** |

## Findings

| # | Finding | Submitted | Final | Status |
|---|---------|-----------|-------|--------|
| F-003 | [Spot/predict trades have no solvency gate — naked short drains the exchange](F-003-naked-short-insolvency.md) | Critical | **Critical** | **Resolved — fixed** |
| F-001 | [Any user can self-mint `ALLOW_ADMIN` — full account takeover](F-001-admin-permission-escalation.md) | Critical | **High** | **Resolved — fixed** |

Both ship a runnable Foundry PoC in [`PoC/`](PoC/) that reaches and asserts the damaging state.

**F-003** was submitted and accepted at Critical; triage's own root-cause write-up matched the
submission near-verbatim.

**F-001** was accepted Critical on 2026-07-03 and re-scored High ten days later — the deployed
system has an off-chain validation layer that rejects a non-admin assigning the admin permission
before it reaches the on-chain flow. That is a mitigating control invisible in the contract source;
the contract-level flaw was still confirmed and fixed. It is the more useful of the two lessons: a
source-only review can identify a real defect correctly and still misjudge its severity, because
severity depends on the deployment as well as the code.

## Note on contest economics

Worth recording plainly, because it shaped how I choose engagements now.

Both findings were valid, and both were found by much of the field: **61 researchers filed F-001,
and 65 filed F-003.** On a reward-sharing pool, a duplicate count in that range reduces every
participant's share to a nominal amount regardless of write-up quality.

The instructive part is the ordering. F-001 was the obvious permission-mask bug — the kind dozens of
people find within an hour. F-003 was the deep one: it required enumerating deployment profiles,
noticing that `CAP_MARGIN_CHECK` is unregistered in two of them, and connecting a no-op margin check
to a bucket-0-only withdrawal gate. I expected depth to be a differentiator.

It was not. **More people found the deep bug than the obvious one.** On a public, frozen, well-known
contest repository, if a bug is real and reachable, the crowd finds it — depth offers no protection
from duplication.

The conclusion I draw is about venue structure rather than technique: finding quality determines
whether you get paid *at all*, but the venue determines whether that payment is meaningful. Depth
earns where a venue rewards uniqueness — private engagements, roster placement, or genuinely fresh
unaudited code — not in a reward-sharing pool on a repository everyone is reading.
