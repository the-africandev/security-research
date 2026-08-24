# Security Audit Reports & Findings

Smart contract security research by **[@the-africandev](https://github.com/the-africandev)**.
This repository is a running record of my audit contest findings, bug bounty submissions, and independent security research.

> Focus: Smart contract security — DeFi, prediction markets, and protocol logic.
> Primarily Solidity / EVM, with incident-analysis work across Move (Aptos), Solana and Hedera.

---

## 📊 Track Record

| Date      | Protocol           | Platform                     | Severity   | Status                 | Report                                                        |
| --------- | ------------------ | ---------------------------- | ---------- | ---------------------- | ------------------------------------------------------------- |
| _2026-06_ | TipRun             | HackenProof (audit contest)  | Critical   | Resolved               | [Writeup](contests/2026-06-tiprun/F-003-naked-short-insolvency.md) |
| _2026-06_ | TipRun             | HackenProof (audit contest)  | High       | Resolved               | [Writeup](contests/2026-06-tiprun/F-001-admin-permission-escalation.md) |
| _2026-06_ | 0xMarkets / Cartha | HackenProof (audit contest)  | High       | Confirmed by team      | [Writeup](contests/2026-06-0xmarkets-cartha/README.md)        |
| _2026-04_ | PasswordStore      | Practice (Cyfrin)            | High · Med | —                      | [PDF](practice/2026-04-25-password-store-report.pdf)          |

<!--
Add newest findings at the TOP. Suggested Status values:
Confirmed · Acknowledged · Fixed · Resolved · Duplicate · Disputed
Keep severities honest — inflated severities are the fastest way to lose credibility.
-->

**Summary:** _3 confirmed production findings — 1 Critical, 2 High, all triage-validated with runnable PoCs. Plus practice exercises._

---

## 🏆 Competitions & Challenges

| Date | Event | Result | Writeups |
| --------- | ------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| _2026-08_ | CertiK Hunt — "Billion Dollar AI Auditor" Challenge | **5th of 22** · 25 incidents claimed · $162.8M loss value scored | [Analyses](independent/2026-08-certik-ai-auditor-challenge/README.md) |

Historical-incident **recovery and root-cause analysis** — reconstructing exploited contracts across patched
proxies, reverted repositories, a decommissioned block explorer, and a chain that publishes no source at all.
This is analysis of already-public exploits, not discovery of new vulnerabilities.

Methodology writeup: [Recovering the Pre-Incident Contract](independent/2026-08-certik-ai-auditor-challenge/recovering-pre-incident-contracts.md).

---

## 🔗 Profiles

- **HackenProof:** [https://hackenproof.com/hackers/theafrodev](https://hackenproof.com/hackers/theafrodev)
- **Sherlock:** [https://audits.sherlock.xyz/watson/TheAfroDev](https://audits.sherlock.xyz/watson/TheAfroDev)
- **Cantina:** [https://cantina.xyz/u/theafrodev](https://cantina.xyz/u/theafrodev)
- **X / Twitter:** [https://x.com/theafro_dev](https://x.com/theafro_dev)

---

## 📁 Repository Structure

| Folder                           | Contents                                                                    |
| -------------------------------- | --------------------------------------------------------------------------- |
| [`contests/`](contests/)         | Findings from competitive audits (Code4rena, Sherlock, Cantina, CodeHawks)  |
| [`bug-bounties/`](bug-bounties/) | Bug bounty submissions (Immunefi, HackenProof) — redacted per program rules |
| [`independent/`](independent/)   | Self-directed deep-dives on live or public protocols                        |
| [`practice/`](practice/)         | Training exercises and first-flights (learning, not production findings)    |
| [`_templates/`](_templates/)     | Reusable finding-writeup + Foundry PoC templates                            |

Each engagement lives in its own dated folder — e.g. `contests/2026-05-<protocol>/` — containing a `README.md` writeup and, where applicable, a runnable `PoC/`.

---

## ✍️ About

I'm a smart contract security researcher specializing in EVM/Solidity. I hunt for logic
errors, access-control gaps, economic/oracle manipulation, and the business-logic bugs that
pattern-matching tools miss. Every finding here includes a root-cause writeup and, where the
target allows, a runnable proof of concept.

**Available for:** private audits · audit-firm roles · bug bounty collaborations.
**Contact:** [theafricandev1@gmail.com](mailto:theafricandev1@gmail.com) / X [DM](https://x.com/theafro_dev)

---

_Disclosure note: bug bounty findings are published only after remediation and in accordance
with each program's disclosure policy. Nothing here is disclosed in violation of an active embargo._
