# BVS — Blockchain Voting System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.29-363636.svg)](https://soliditylang.org)
[![Foundry Tests](https://img.shields.io/badge/Foundry_Tests-98_passing-brightgreen.svg)](https://getfoundry.sh)
[![SvelteKit](https://img.shields.io/badge/SvelteKit-Frontend-FF3E00.svg)](https://kit.svelte.dev)

BVS gives any organization—a corporation, a foundation, an NGO, or a (local) government entity—a tool to engage its stakeholders to vote for standards, policies, and resolutions while using blockchain technology.

Why do we need this?

One of the (many) problems of the traditional governance tools in the crypto industry is that they reduce human cooperation into an "American startup." This leaves most other forms of organization (of which there are many more than startups) unable to legally use beneficial blockchain tools.

The BVS addresses this issue by specifically not raising funds, trying to be decentralized, or pretending to be an organization. Instead, it is a simple tool for one legal entity to engage stakeholders and record votes and legislation on the blockchain. It is a way to use the beneficial voting and registration tools created for DAOs but without the legal complexity.

Those using a BVS do not raise funds, their non-tradable tokens do not create financial products, and there is no shared risk or liability. Legally, it's simply one company recording input from its stakeholders.

Part of the [Vattelum](https://github.com/vattelum) ecosystem.

## Demo

https://github.com/user-attachments/assets/5bce30e5-9f05-465b-a14e-1a980d423815

## How It Works

The BVS is run by a single admin.

One wallet deploys the contracts, manages membership, and registers documents. Stakeholders receive soulbound membership tokens that grant them the right to vote on proposals through [Snapshot](https://snapshot.org), an off-chain voting protocol. One token equals one vote.

The BVS combines three pieces of blockchain infrastructure:

1. **Membership tokens** — Soulbound (non-transferable) ERC-721 tokens that represent membership. One token per address. The token grants voting rights and serves as verifiable on-chain proof of membership.

2. **Permanent storage** — Ratified documents (bylaws, resolutions, policies) are uploaded to **[Arweave](https://arweave.org)**, for permanent storage. Each upload produces a transaction ID that serves as a permanent link to the full text.

3. **On-chain registry** — A smart contract on **Ethereum** records the Arweave transaction ID, a SHA-256 content hash, title, category, version number, and a reference to the Snapshot vote that approved it. This creates a verifiable index of all ratified legislation.

The result is a governance system where every decision is recorded, every document is permanent, and every record is independently verifiable. Any stakeholder can verify that a document is authentic and unmodified by fetching it from Arweave, hashing its contents, and comparing the result to the on-chain record.

## Features

- **Soulbound membership** — Non-transferable ERC-721 tokens with on-chain credential storage. One token per address, admin-minted, holder-burnable.
- **Snapshot voting** — Off-chain gasless voting linked to membership tokens. Vote IDs are recorded alongside ratified documents.
- **Document types** — Each document is classified as Original, Amendment, Revision, Repeal, or Codification, creating a clear legislative lifecycle.
- **Section-level targeting** — Amendments and repeals can target specific sections of an existing document, not just the document as a whole.
- **External references** — Documents can reference other on-chain documents with relationship types (governs, amends, supersedes, implements, references).
- **Relationship tags** — The homepage displays document relationships and supersession status, showing the full lifecycle of each piece of legislation.

## Architecture

**Smart Contracts** (Solidity 0.8.29, OpenZeppelin 5.x):
- `BVSToken.sol` — ERC-721 + ERC-5192 soulbound membership token with credential storage
- `BVSRegistry.sol` — Append-only document registry with categories, versioning, and governance authority control

**Frontend** (SvelteKit, Tailwind CSS):
- `/` — Public registry browser. Loads categories and documents from the contract, fetches full text from Arweave on demand.
- `/propose` — Structured markdown editor with section numbering (§1, §1.1, §1.1.A), Arweave upload, and on-chain recording. Admin-gated.
- `/admin` — Member list from contract events, token minting form. Mint is admin-gated.

**External Services**:
- [Snapshot](https://snapshot.org) — Off-chain voting (ERC-721 strategy, one token = one vote)
- [Arweave](https://arweave.org) — Permanent document storage via [ArDrive Turbo](https://ardrive.io)

## Quick Start

### Browse the demo

The repository ships with a live demo deployment on Sepolia testnet. To see it in action:

1. Clone the repository
2. Copy `.env.example` to `.env` in `apps/frontend/`
3. Run `npm install && npm run dev`
4. Open the app in your browser — the registry loads with some example documents you can browse immediately

### Deploy your own

To create your own BVS you must deploy new smart contracts and update the frontend with your contract addresses.

You are free to select your own categories of legislation you wish to include in your registry.

#### Prerequisites

- [Node.js](https://nodejs.org) 18+
- [Foundry](https://getfoundry.sh) (for contract compilation, testing, and deployment)
- An Ethereum wallet (MetaMask, Ledger, etc.)

#### 1. Deploy the contracts

The contracts can be deployed to any EVM-compatible network (Ethereum, Arbitrum, Base, Sepolia, etc.).

```sh
cd apps/contracts
forge install
forge build
forge test
```

Configure your deployment environment and deploy using Foundry.

The deployment script (`script/Deploy.s.sol`) deploys both contracts and seeds starter document categories. For example, resolutions, governance documents or policies. You are completely free to create your own categories. Make sure to edit the script to customize the category names and number of categories for your organization before deploying.

#### 2. Create Snapshot space

Create a Snapshot space at [snapshot.org](https://snapshot.org) (or [testnet.snapshot.box](https://testnet.snapshot.box) for testing) with:
- **Strategy**: `erc721` pointing to your deployed BVSToken contract address
- **Network**: The chain you deployed to
- **Voting**: Single choice, your preferred voting period and quorum

Snapshot requires an ENS domain (e.g., `your-org.eth`) to create a space. You can register one at [app.ens.domains](https://app.ens.domains).

#### 3. Configure and run frontend

```sh
cd apps/frontend
npm install
cp .env.example .env
```

Edit `.env` with your deployed contract addresses, chain ID, RPC URL, and Snapshot space.

```sh
npm run dev
```

Connect with the deployer wallet—the same wallet you used to deploy the smart contract—to access admin functions (minting tokens, submitting documents).

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

1. **Mint a membership token** — Go to Members, enter a recipient address, click Mint
2. **Create a Snapshot proposal** — Go to your Snapshot space and create a proposal. The proposal title and description are for discussion; the actual document text will be drafted in the BVS editor after the vote passes.
3. **Vote** — Token holders vote on the proposal in Snapshot
4. **Draft a document** — Go to Propose, write or import the approved document
5. **Upload and record** — Select the category, link the Snapshot vote ID, click Review & Upload, confirm
6. **Verify** — The document appears on the homepage under its category with a link to the vote

## Configuration

If you deploy your own contracts, you must update two files to correctly point the BVS to them.

### Contracts `.env`

| Variable | Description |
|---|---|
| `SEPOLIA_RPC_URL` | RPC endpoint for your target network |
| `PRIVATE_KEY` | Deployer wallet private key (WARNING: storing private keys in an .env file is a security risk, especially on mainnet. See `.env.example` for safer alternatives including hardware wallets and encrypted keystores) |

### Frontend `.env`

| Variable | Description |
|---|---|
| `VITE_BVS_TOKEN_ADDRESS` | Deployed BVSToken contract address |
| `VITE_BVS_REGISTRY_ADDRESS` | Deployed BVSRegistry contract address |
| `VITE_CHAIN_ID` | Chain ID of your target network |
| `VITE_DEPLOY_BLOCK` | Block number of contract deployment (for efficient log fetching) |
| `VITE_RPC_URL` | RPC endpoint |
| `VITE_SNAPSHOT_SPACE` | Snapshot space name (e.g., `your-org.eth`) |
| `VITE_SNAPSHOT_HUB` | Snapshot hub URL |

## Forward Compatibility

BVS is the second product in the Vattelum ecosystem. The smart contracts include fields that enable the upgrade path to more advanced governance products:

- **`IVerifier`** — Pluggable verification gate for token minting (used for open registration in future products)
- **Amendment restrictions** — Category-level rules for locked sections, amendment thresholds, and minimum time between amendments

These fields are tested in `ForwardCompat.t.sol` (25 tests) to ensure they store and retrieve correctly.

## License

MIT
