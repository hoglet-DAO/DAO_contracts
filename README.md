# Hoglet DAO Factory

**Community-governed ve(3,3) governance infrastructure built on Supra Move.**  
Deploy sovereign, on-chain DAOs powered by vote-escrowed NFTs, Synthetix-style reward gauges, weekly emission cycles, and timelocked execution.

🌐 **Live Testnet:** [https://daos.hoglet.xyz](https://daos.hoglet.xyz)  
📖 **Architecture & Lifecycle Guide:** [`DAO_FACTORY_LIFECYCLE.md`](./DAO_FACTORY_LIFECYCLE.md)  
🛡️ **Security Audits:** [`audits/`](./audits/)  
📄 **License:** [`LICENSE.md`](./LICENSE.md)

---

## ⚡ Overview & Value Proposition

Instead of building decentralized governance from scratch or relying on centralized multisigs, **Hoglet DAO Factory** allows any protocol to deploy a self-sustaining, game-theoretic DAO in a single transaction.

- **ve(3,3) Tokenomics:** Long-term alignment via vote-escrowed Fungible Assets encapsulated in transferrable Move V2 Objects (`0x4`).
- **Inflation & Streaming Gauges:** Automated weekly epoch rollover (`jubilee`), continuous reward streaming via Synthetix-style gauges (`foundry`), and bribe markets (`restore`).
- **Sovereign Execution & Timelock:** Full on-chain proposal lifecycle (`herald`, `witness`, `ledger`, `anchor`) with delay windows, dynamic quorums, late-quorum sniper protection, and grace periods.
- **Smart Token & Fiscal Router:** Native fee-on-transfer hooks, anti-whale throttles, and capabilities-gated exemptions via `tax_router` (`TaxFreeCap`).

Everything is **source-available**.  
Everything is **on-chain**.  
Everything is **community-governed**.

---

## 🏛️ Core Architecture & Move Modules

The DAO Factory is organized into modular packages under the Supra Move framework:

```
dao_hoglet/
├── dao_factory/        # Core protocol engines
│   ├── petra.move      # Factory deployer & two-step admin transfer
│   ├── charter.move    # Constitutional rules, quorums, timelock & guardian
│   ├── legacy.move     # veNFT logic (lock, extend, split, merge, checkpoints)
│   ├── jubilee.move    # Weekly inflation minter & decay engine
│   ├── zeal.move       # Gauge registry & weekly emission weight voting
│   ├── foundry.move    # Synthetix reward streaming with NFT working-balance boost
│   ├── harvest.move    # Fee distributor & rebase compounding for lockers
│   ├── restore.move    # Bribe accumulation & distribution per epoch
│   ├── herald.move     # Proposal creation & parameter validation
│   ├── witness.move    # Historic voting tally (now - 1) & late quorum extension
│   ├── anchor.move     # Execution timelock, proposal queue & action dispatch
│   ├── ledger.move     # State storage & internal DAO signer generator
│   ├── sentinel.move   # Emergency circuit-breaker pause & auto-expiry cooldown
│   └── seal.move       # SignerCapability custody for resource accounts
├── dao_tokens/         # smart_token (FA dispatch hooks, taxes, anti-whale)
├── dao_tax_router/     # tax_router (TaxFreeCap routing with store ownership guards)
├── dao_router/         # High-level entrypoint wrappers (setup, zap, staking, proposals)
├── dao_scripts/        # vault & library (whitelisted Move bytecode scripts)
├── dao_boost/          # boost_registry (NFT collection multipliers)
└── dao_views/          # Optimized view functions for indexers and frontends
```

---

## 🛡️ Security & Formal Audits

Security is paramount. The codebase has undergone comprehensive, multi-phase static analysis and line-by-line verification:

- **Audit Reports:** Full audit reports, threat models, and verified remediations are documented in [`audits/`](./audits/) (V1 through V6).
- **Accounting Isolation:** All internal protocol accounting relies strictly on internal virtual balances, immune to external balance manipulation or un-tracked donations.
- **Historic Voting Snapshots:** Governance voting power reads snapshots at epoch $now - 1$ to eliminate flash-loan attacks and block-level vote recycling.

---

## 🔒 Responsible Vulnerability Disclosure & Bug Bounty

If you discover a security vulnerability or potential flaw in the Hoglet DAO Factory smart contracts, **DO NOT exploit it on public networks or disclose it publicly**.

Please submit a confidential report to our security team:
- **Email:** `security@hoglet.xyz`
- **PGP / Secure Channel:** Available upon request.

Responsible disclosures that adhere to safe coordination practices are eligible for bug bounty compensation based on severity as determined by Hoglet DAO.

---

## ⚖️ Legal Disclaimer & Terms of Use

### 1. Software "As-Is" (Testnet Stage)
This software is provided **"AS IS"** and **"AS AVAILABLE"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. While extensive security audits have been conducted, decentralized systems carry inherent smart contract, cryptographic, and economic risks.

### 2. Non-Custodial & Neutral Infrastructure
Hoglet DAO Factory is a decentralized, non-custodial set of tools. The core developers, contributors, and Hoglet DAO do not control, manage, or hold custody over funds, digital assets, or treasuries created by third parties using this infrastructure.

### 3. Builder & User Responsibility
Users, deployers, and third-party projects are solely responsible for conducting their own technical, legal, and economic due diligence before deploying or interacting with any DAO, token, or smart contract. Each participant is responsible for ensuring compliance with all applicable laws and regulations in their respective jurisdiction.

---

## 📄 License & Source-Available Policy

This software is released under the **Hoglet DAO Smart Contracts License (Source-Available & Restricted Commercial Use)**. 

- **Auditing, Inspection & Education:** Free and permitted.
- **Commercial Deployment & Competing Forks:** Strictly prohibited without an on-chain DAO governance waiver.
- **Governance Transition:** Through transparent on-chain proposals, the **Hoglet DAO** retains the exclusive right to grant partner exemptions or transition this codebase to an OSI-approved open-source license (such as MIT, Apache 2.0, or BSL 1.1).

For complete legal terms, review the [`LICENSE.md`](./LICENSE.md) file.
