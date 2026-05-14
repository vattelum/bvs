# BVS — Blockchain Voting System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.31-363636.svg)](https://soliditylang.org)
[![Foundry Tests](https://img.shields.io/badge/Foundry_Tests-89_passing-brightgreen.svg)](https://getfoundry.sh)
[![SvelteKit](https://img.shields.io/badge/SvelteKit-Frontend-FF3E00.svg)](https://kit.svelte.dev)

BVS gives any organization—a corporation, a foundation, an NGO, or a (local) government entity—a tool to engage its stakeholders to vote for standards, policies, and resolutions while using blockchain technology.

Why do we need this?

One of the (many) problems of the traditional governance tools in the crypto industry is that they reduce human cooperation into an "American startup." This leaves most other forms of organization (of which there are many more than startups) unable to legally use beneficial blockchain tools.

The BVS addresses this issue by specifically not raising funds, trying to be decentralized, or pretending to be an organization. Instead, it is a simple, legally neutral tool for an organization to engage stakeholders and record votes and legislation on the blockchain. It is a way to use the beneficial voting and registration tools created for DAOs but without the legal complexity.

Those using a BVS do not raise funds, their non-tradable tokens do not create financial products, and there is no shared risk or liability. Legally, it's simply one company recording input from its stakeholders.

Non-financial use adds significant value to any blockchain in an industry rife with compliance issues.

Part of the [Vattelum](https://github.com/vattelum) ecosystem.

## Demo

https://github.com/user-attachments/assets/5bce30e5-9f05-465b-a14e-1a980d423815

## How It Works

The BVS is run by a single admin.

One wallet deploys the contracts, manages membership, and decides which proposals get recorded on-chain in the BVS registry.

Stakeholders receive soulbound membership tokens and vote on proposals through [Snapshot X](https://docs.snapshot.box/) (on-chain voting). One token equals one vote.

The BVS combines four pieces of blockchain infrastructure:

1. **Membership tokens** — Soulbound (non-transferable) ERC-721 tokens that represent membership. One token per address. Admin-minted, holder-burnable.

2. **On-chain voting (Snapshot X)** — A Snapshot X Space deployed on the same chain as the BVS contracts. Members vote For / Against / Abstain. Voting is fully on-chain—every vote is a transaction.

3. **Permanent storage (Arweave)** — Proposed documents are uploaded to [Arweave](https://arweave.org) via [ArDrive Turbo](https://ardrive.io) using the proposer's wallet. The Arweave transaction ID and a SHA-256 content hash are encoded into the Snapshot X proposal payload.

4. **On-chain registry** — `BVSRegistry` records the ratified document's Arweave URI, content hash, title, category, version, and a reference back to the Snapshot X proposal that ratified it. The admin records both ratifications (`addDocument`) and rejections (`rejectProposal`, event-only, with the recorded vote tally).

The result is a governance system where every vote, every ratified document, and every rejection is independently verifiable: the on-chain content hash can be checked against the Arweave document, and the Snapshot X proposal can be inspected for the vote that produced it.

## Features

- **Soulbound membership** — Non-transferable ERC-721 tokens with on-chain credential storage. Admin-minted; holder- and admin-burnable.
- **Snapshot X voting** — On-chain voting via sx-evm contracts on the same network as the BVS contracts. No off-chain Snapshot v2 dependency.
- **Document types** — Each document is classified as Original, Amendment, Revision, Repeal, or Codification, creating a clear legislative lifecycle.
- **Section-level targeting** — Amendments and repeals can target specific sections of an existing document, not just the document as a whole.
- **External references** — Documents can reference other on-chain documents with relationship types (amends, revises, repeals, codifies, governs, implements, references, template).
- **Approve / Reject** — Admin records the outcome of every proposal: `addDocument` for ratifications, `rejectProposal` (event-only) for rejections, both at any time.

## Architecture

**Smart Contracts** (Solidity 0.8.31, OpenZeppelin 5.x):
- `BVSToken.sol` — ERC-721 + ERC-5192 soulbound membership token with credential storage. Admin-only mint, holder self-burn or admin burn, optional verifier gate.
- `BVSRegistry.sol` — Append-only document registry with categories, document layer, version chains, and a single `governanceAuthority` (admin EOA). Supports per-document amendment restrictions (`setAmendmentRestrictions` / `getAmendmentRestrictions` with locked sections and minimum time between amendments) gated by an immutable `hardLock` constructor flag. Includes `rejectProposal()` for the audit trail.
- `lib/document-registry/` — `@vattelum/document-registry` shared standard.
- `lib/sx-evm/` — Snapshot X contracts (Space, EthTxAuthenticator, VanillaVotingStrategy, VanillaExecutionStrategy, and a proposal-validation strategy — `VanillaProposalValidationStrategy` for open proposing or `WhitelistProposalValidationStrategy` for admin-only).

**Frontend** (SvelteKit static SPA, Tailwind CSS):
- `/` — Public registry browser. Categories → documents → versions; document content fetched from Arweave on demand.
- `/admin` — Member list (from `Transfer` / burn events), admin-gated mint form, holder self-burn.
- `/propose` — Structured markdown editor with section numbering (§1, §1.1, §1.1.A), Arweave upload, Snapshot X proposal creation. Gated by `VITE_MEMBERS_CAN_PROPOSE` to mirror the Space's proposal-validation strategy.
- `/vote` — Active proposals with on-chain vote buttons (For / Against / Abstain). Admin sees **Approve & Record** and **Reject** buttons on every proposal at any time.

**External Services**:
- [Snapshot X](https://docs.snapshot.box/) — On-chain voting via sx-evm contracts.
- [Arweave](https://arweave.org) — Permanent document storage via [ArDrive Turbo](https://ardrive.io).

## Quick Start

### Browse the demo

The repository ships with a live demo deployment on Sepolia testnet. To see it in action:

1. Clone the repository
2. Copy `.env.example` to `.env` in `apps/frontend/`
3. Run `npm install && npm run dev`
4. Open the app in your browser—the registry loads with an example document you can browse immediately

### Deploy your own

To create your own BVS you must deploy new smart contracts and update the frontend with your contract addresses.

You are free to select your own categories of legislation you wish to include in your registry.

#### Prerequisites

- [Node.js](https://nodejs.org) 18+
- [Foundry](https://getfoundry.sh) (for contract compilation, testing, and deployment)
- An Ethereum wallet (MetaMask, Ledger, etc.)

#### 1. Deploy the contracts

The contracts can be deployed to any EVM-compatible network where Snapshot X (sx-evm) is also deployed (Ethereum, Optimism, Polygon, Arbitrum, Base, Sepolia, and others). The sx-evm primitive addresses differ per chain.

`02_CreateVotingSpace.s.sol` ships with the Sepolia values and a comment block pointing at the Snapshot X deployments page for non-Sepolia chains.

```sh
cd apps/contracts
forge install
forge build
forge test
```

Three numbered scripts stand up a fresh BVS instance. They run in order:

```sh
cd apps/contracts
cp .env.example .env  # set PRIVATE_KEY (and optionally ADMIN_ADDRESS, BVS_HARD_LOCK)

# 1. Deploy BVSToken + BVSRegistry, seed initial categories
forge script script/01_Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# 2. Deploy a Snapshot X Space wired to your token
forge script script/02_CreateVotingSpace.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# 3. Deploy a VanillaExecutionStrategy (quorum=1) referenced by every BVS proposal
forge script script/03_DeployExecutionStrategy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

`01_Deploy.s.sol` seeds three default categories (Constitutional Law, Operational Policy, Resolutions), edit the script if you want different names. If you set `ADMIN_ADDRESS` in `.env` to an address other than the deployer, the script transfers token ownership and registry governance to that address at the end. The optional `BVS_HARD_LOCK` env var (default `false`) is baked into the immutable `hardLock` constructor flag—see Configuration.

`02_CreateVotingSpace.s.sol` deploys a Snapshot X Space using the sx-evm `ProxyFactory`. The Space address is emitted in a `ProxyDeployed` log—copy it from the broadcast output into `apps/frontend/.env` as `VITE_SX_SPACE_ADDRESS`.

`03_DeployExecutionStrategy.s.sol` deploys the `VanillaExecutionStrategy` (quorum = 1) that every BVS proposal references at creation time. Copy the printed address into `apps/frontend/.env` as `VITE_EXECUTION_STRATEGY_ADDRESS`. If a suitable `VanillaExecutionStrategy` is already deployed on your target chain you can reuse its address and skip this script entirely.

There is no Gnosis Safe and no `.eth` ENS step. The admin records ratifications and rejections directly from the `/vote` page.

#### Change vote duration after deployment

The admin may want to change the voting period after deployment, either shortening it for testing, or lengthening it to give voters more time. The script `ReduceVotingPeriod.s.sol` calls `Space.updateSettings()` on an already-deployed Space and rewrites `minVotingDuration` and `maxVotingDuration` to whatever you set.

Like every script in `apps/contracts/script/`, this is a template, not a fixed command. Open the `.s.sol` file, set the two duration constants (in seconds) to the window your organisation actually wants, then run:

```sh
forge script script/ReduceVotingPeriod.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

#### 2. Configure and run frontend

```sh
cd apps/frontend
npm install
cp .env.example .env
```

Edit `.env` with the addresses printed by the deploy scripts (`VITE_BVS_TOKEN_ADDRESS`, `VITE_BVS_REGISTRY_ADDRESS`, `VITE_SX_SPACE_ADDRESS`, `VITE_AUTHENTICATOR_ADDRESS`, `VITE_EXECUTION_STRATEGY_ADDRESS`, `VITE_ADMIN_ADDRESS`, `VITE_DEPLOY_BLOCK`).

```sh
npm run dev -- --host
```

The `--host` flag is required (per project constitution §6).

Connect with the admin wallet to mint tokens and to use the Approve & Record / Reject buttons on `/vote`.

### Arweave Setup and Document Registration

The BVS uses [ArDrive Turbo](https://ardrive.io) to upload documents to Arweave. As a result, you can simply connect with the same MetaMask (or similar) admin account. No separate Arweave wallet or AR tokens are required.

ArDrive Turbo offers a 100 KiB free tier. So it is possible that you do not have to pay anything to store your initial legislation. In fact, during the development of this project no payment was asked, and storage happened almost instantly.

The full document storage requires three signatures from your wallet:

1. **Connect signature** — A one-time wallet signature to authenticate with the Turbo service (once per session).
2. **Arweave upload** — The wallet signs the data item for permanent storage on Arweave.
3. **On-chain registration** — A standard Ethereum transaction to record the document in the registry contract.

If you upload large-sized or a large amount of documents, your transaction might be refused pending the funding of your account.

In that case:

1. Go to [app.ardrive.io](https://app.ardrive.io) and connect your Ethereum wallet
2. Purchase Turbo credits using ETH (a small amount covers many documents)

### Test the full flow

1. **Mint a membership token** — Connect the admin wallet on `/admin`, enter a recipient address, click Mint Token.
2. **Draft & propose** — Go to `/propose`, write or import a markdown document. Click Review & Submit Proposal: the document is uploaded to Arweave (one wallet signature) and a Snapshot X proposal is created (one transaction).
3. **Vote on-chain** — Token holders go to `/vote` and click For / Against / Abstain. Each vote is an on-chain transaction.
4. **Approve or reject** — The admin returns to `/vote` and clicks **Approve & Record** to call `BVSRegistry.addDocument()`, or **Reject** with an optional reason to call `BVSRegistry.rejectProposal()`. Both buttons are available at any time.
5. **Verify** — Approved documents appear on the homepage under their category. Rejected proposals appear in `/vote` history with the recorded tally and reason.

## Configuration

If you deploy your own contracts, you must update two files to correctly point the BVS to them.

### Contracts `.env`

| Variable | Description |
|---|---|
| `SEPOLIA_RPC_URL` | RPC endpoint for Sepolia (testnet deployments) |
| `MAINNET_RPC_URL` | RPC endpoint for Ethereum mainnet (optional; used only for mainnet deploys) |
| `PRIVATE_KEY` | Deployer wallet private key (WARNING: storing private keys in an .env file is a security risk, especially on mainnet. See `.env.example` for safer alternatives including hardware wallets and encrypted keystores) |
| `ADMIN_ADDRESS` | Optional. If set and different from the deployer, `01_Deploy.s.sol` transfers token ownership and registry governance to this address at the end. Defaults to the deployer. |
| `BVS_HARD_LOCK` | Optional, default `false`. When `true`, `01_Deploy.s.sol` constructs `BVSRegistry` with the immutable hard-lock posture: `setAmendmentRestrictions` reverts while a lock window is active. When `false` (soft-lock), admin can adjust restrictions at any time. |
| `ETHERSCAN_API_KEY` | Optional. Required only if you pass `--verify` to a deploy script for source-code verification on Etherscan. |

### Frontend `.env`

| Variable | Description |
|---|---|
| `VITE_BVS_TOKEN_ADDRESS` | Deployed BVSToken contract address |
| `VITE_BVS_REGISTRY_ADDRESS` | Deployed BVSRegistry contract address |
| `VITE_SX_SPACE_ADDRESS` | Snapshot X Space (from `02_CreateVotingSpace.s.sol`) |
| `VITE_AUTHENTICATOR_ADDRESS` | sx-evm `EthTxAuthenticator` |
| `VITE_EXECUTION_STRATEGY_ADDRESS` | sx-evm `VanillaExecutionStrategy` |
| `VITE_ADMIN_ADDRESS` | Admin EOA (matches `BVSToken.owner()` / `BVSRegistry.governanceAuthority()`) |
| `VITE_CHAIN_ID` | Chain ID of your target network |
| `VITE_DEPLOY_BLOCK` | Block number of contract deployment (for efficient log fetching) |
| `VITE_RPC_URL` | RPC endpoint |
| `VITE_MEMBERS_CAN_PROPOSE` | `true` to allow all members to propose, `false` for admin-only (default). Must mirror the Snapshot X Space's proposal-validation strategy. |

## Forward Compatibility

BVS is Product 2 in the [Vattelum](https://github.com/vattelum) ecosystem. It deliberately reuses the same primitives as DAA (Product 3) and the upcoming Individual Contracts / SCB products:

- **`@vattelum/document-registry`** — Shared Solidity + JS document standard (categories, document layer, version chains, references).
- **`IVerifier`** — Pluggable verification gate for token minting.
- **`contentUri`** — Storage-agnostic document URI (Arweave today; other carriers later).
- **Snapshot X (sx-evm)** — Shared on-chain voting layer across Vattelum products.

Differences vs. DAA are intentional simplifications for the centralized-organization model: admin-only mint (no fee), single governance authority (no two-tier), single execution strategy (no Gnosis Safe), and admin discretion replaces threshold-gated execution. BVS keeps on-chain amendment restrictions, gated by the registry's immutable `hardLock` flag.

## User-Suggested Use Cases

**Dynamic Terms & Conditions** — A website owner can link her website's T&Cs directly to a Registry document. Letting clients adjust selected aspects of the terms and conditions—in this case the licensing of software—increases engagement and feelings of ownership. Since website terms bind visitors through use rather than individual contracts, any website can include dynamic terms for its products with no added legal complexity.

## License

MIT
