# Auction Prediction Market — Deployment & Operations Guide

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Local Setup](#3-local-setup)
4. [Compile & Run Tests](#4-compile--run-tests)
5. [Environment Configuration](#5-environment-configuration)
6. [Deploy to Arc Testnet](#6-deploy-to-arc-testnet)
7. [Post-Deployment Verification](#7-post-deployment-verification)
8. [Contract Verification on Etherscan](#8-contract-verification-on-etherscan)
9. [System Lifecycle](#9-system-lifecycle)
   - [Phase 1: Publishing Rights Auction](#phase-1-publishing-rights-auction)
   - [Phase 2: Prediction Market](#phase-2-prediction-market)
10. [Cast Interaction Cheat Sheet](#10-cast-interaction-cheat-sheet)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Architecture Overview

The system has **4 contracts** working in two sequential phases:

```
┌─────────────────────────────────────────────────────────┐
│                     PHASE 1: AUCTION                      │
│                                                           │
│  Backend ──► AuctionManager ──► PublishingRightsNFT       │
│  (creates       (bidding,           (ERC-721 token         │
│   auctions)     shortlist,          minted to winner)      │
│                 resolution)                                │
│                                                           │
│  Bidders stake native currency and submit proposals. Backend runs AI     │
│  filtering + expert evaluation. Oracle signs the winner.                  │
│  Winner gets an NFT. Non-winners withdraw stakes.                         │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                   PHASE 2: PREDICTION MARKET               │
│                                                           │
│  NFT Holder ──► MarketFactory ──► PredictionMarket         │
│  (owns token)   (deploys market   (betting, resolution,   │
│                  per token)        fee distribution)       │
│                                                           │
│  Bettors wager native currency on outcomes. Publisher earns fees.         │
│  Oracle resolves. Winners claim proportional payouts.                     │
│  Publisher claims accumulated fees via the NFT contract.                  │
└─────────────────────────────────────────────────────────┘
```

| Contract | File | Role |
|---|---|---|
| `PublishingRightsNFT` | `src/PublishingRightsNFT.sol` | ERC-721 token representing publishing rights. Minted to auction winners. |
| `AuctionManager` | `src/AuctionManager.sol` | Manages Phase 1 auctions: bidding, shortlist, oracle resolution. |
| `MarketFactory` | `src/MarketFactory.sol` | Deploys `PredictionMarket` instances. One market per NFT token. |
| `PredictionMarket` | `src/PredictionMarket.sol` | Per-market betting contract with parimutuel payouts and publisher fees. |

---

## 2. Prerequisites

- **[Foundry](https://book.getfoundry.sh/getting-started/installation)** (Forge, Cast, Anvil)
- **Git**
- **A wallet with Arc Testnet native USDC** — USDC is the gas currency. Get testnet USDC from the Arc faucet.
- **Arc Testnet RPC URL** — register at the network's faucet / docs

Verify your installation:

```shell
forge --version   # should be ≥ nightly-2024
cast --version
```

---

## 3. Local Setup

```shell
# Clone with submodules
git clone --recurse-submodules git@github.com:Cypher-Lexicon/auction-prediction-market.git
cd auction-prediction-market

# Install Solidity dependencies (forge-std, openzeppelin-contracts v4.9.6)
forge install
```

What this does: `forge install` reads `.gitmodules` (like Python's `requirements.txt`) and downloads `forge-std` and `openzeppelin-contracts@v4.9.6` into `lib/`.

---

## 4. Compile & Run Tests

```shell
# Compile all contracts
forge build

# Run the full test suite
forge test

# Run with verbose output (see each test)
forge test -vvv

# Run a specific test file
forge test --match-path test/AuctionManager.t.sol -vvv
forge test --match-path test/PredictionMarket.t.sol -vvv

# Run a specific test function
forge test --match-test testFullLifecycle -vvv
```

You should see all tests pass. The tests cover:
- **AuctionManager**: bidding, shortlisting, ECDSA oracle resolution, stake withdrawals
- **PredictionMarket**: market creation, betting, resolution, parimutuel payouts, publisher fees
- **PublishingRightsNFT**: minting, minter management, fee claims via NFT proxy

---

## 5. Environment Configuration

Copy the template and fill in your values:

```shell
cp .env.example .env
```

### Variable reference — INPUT vs OUTPUT

**INPUT** = you must set this before running `forge script`.<br>
**OUTPUT** = the deploy script generates this (an on-chain contract address).

| Variable | I/O | Used by contract(s) | What it is |
|---|---|---|---|
| `ARC_TESTNET_RPC_URL` | INPUT | (network) | HTTP RPC endpoint for Arc Testnet |
| `DEPLOYER_PRIVATE_KEY` | INPUT | (deployer wallet) | Private key that pays gas. Needs testnet USDC. |
| `ORACLE_WITNESS_ADDRESS` | INPUT | **AuctionManager** + **MarketFactory** | Public key of the oracle witness. Its matching private key signs resolution attestations off-chain. The oracle never sends txs. |
| `SIGNER_ADDRESS` | INPUT | **AuctionManager** | Public key whose matching private key (held off-chain) signs on-chain write transactions (`createAuction`, `setShortlist`). |
| `PLATFORM_FEE_RECIPIENT` | INPUT | **MarketFactory** | Wallet that receives the platform's fee cut from publisher fees. |
| `MARKET_FACTORY_PLATFORM_FEE_BPS` | INPUT | **MarketFactory** | Platform fee in basis points (1000 = 10%). |
| `ETHERSCAN_API_KEY` | INPUT | (verification) | ArcScan API key for `forge verify-contract`. |
| *(no env var)* | **OUTPUT** | **PublishingRightsNFT** | `0x...` — printed to console after deploy. |
| *(no env var)* | **OUTPUT** | **AuctionManager** | `0x...` — printed to console after deploy. |
| *(no env var)* | **OUTPUT** | **MarketFactory** | `0x...` — printed to console after deploy. |

### Native Currency

The system uses the **native Arc testnet currency** (USDC) for all on-chain value flows.
This is the same currency used for gas — no separate ERC-20 token contract is needed.

```
Native Arc currency (USDC)
    │
    ├── Gas: every cast send / forge script needs USDC for tx fees
    │
    └── Application: bids, stakes, bets, payouts, fees all use msg.value / call{value}
```

#### How it works in the code

Every incoming value comes via `msg.value`:

```solidity
// Receiving a bid stake
require(msg.value >= a.minimumStake, "Stake too low");
```

Every outgoing value uses `call{value}`:

```solidity
// Sending funds to a user
(bool sent, ) = payable(msg.sender).call{value: amount}("");
require(sent, "Transfer failed");
```

No `approve()` is needed — users just send native value with their transaction.

### What "ORACLE_WITNESS_ADDRESS" actually means

`ORACLE_WITNESS_ADDRESS` is **NOT a URL, not an API endpoint, not a smart contract.**
It is a plain Ethereum wallet address (`0x...`). The key distinction:

```
SIGNER_ADDRESS  —  signs & sends transactions ON-CHAIN  (createAuction, setShortlist)
ORACLE_WITNESS_ADDRESS  —  signs attestations OFF-CHAIN         (never sends a tx)
```

**The oracle is a witness, not a transaction sender.** It attests to the truth. Here's how:

1. Experts evaluate finalists off-chain and determine the winner + score
2. The oracle wallet's private key signs the result data off-chain: `keccak256(auctionId, winner, winningScore)`
3. **Anyone** can take that signature and call `resolveAuction()` on-chain — they pay the gas, not the oracle
4. The contract recovers the signer from the signature and checks: `recovered == oracleAddress`

This is a standard **"sign-to-resolve" ECDSA pattern**. The oracle is the source of truth but never
spends gas. Any relayer (backend server, user, bot) can submit the signed result.

```solidity
// In AuctionManager.resolveAuction():
bytes32 messageHash = keccak256(abi.encodePacked(auctionId, winner, winningScore));
address signer = messageHash.toEthSignedMessageHash().recover(oracleSignature);
if (signer != oracleAddress) revert InvalidOracleSignature();
```

The same address is also stored in **MarketFactory** and passed to every **PredictionMarket** it deploys,
so the same oracle key resolves both phases.

### What "SIGNER_ADDRESS" actually means

`SIGNER_ADDRESS` is **not a URL, not a contract address, not a Web2 endpoint.**
It is a plain Ethereum wallet address (`0x...`). Here is the mental model:

```
OFF-CHAIN:  backend server holds the SIGNER private key
            │
            │ signs a transaction (createAuction, setShortlist)
            ▼
ON-CHAIN:   AuctionManager checks: msg.sender == SIGNER_ADDRESS?
            ├─ yes → tx executes
            └─ no  → reverts with NotBackend
```

It is a **verification anchor**: the public key lives on-chain as a constant
that proves any write to `createAuction()` or `setShortlist()` came from the
entity holding the matching private key. Anyone else's transaction is rejected.

In [AuctionManager.sol](src/AuctionManager.sol), two functions are gated by the `onlyBackend` modifier:

```solidity
modifier onlyBackend() {
    if (msg.sender != backendAddress) revert NotBackend();
    _;
}
```

| Function | Who can call it |
|---|---|
| `createAuction()` | Only `backendAddress` |
| `setShortlist()` | Only `backendAddress` |

Your off-chain backend server generates a wallet (e.g. `cast wallet new`), stores its private key,
and uses it to sign transactions whenever it needs to create an auction or set a shortlist.
If anyone else tries, the contract reverts with `NotBackend`.

**It is access control — nothing more.**

### Generating oracle and backend wallets

These are just Ethereum keypairs. Generate them before deployment:

```shell
# Oracle witness wallet (public key → ORACLE_WITNESS_ADDRESS, private key → kept secret for off-chain signing)
cast wallet new

# Signer wallet (public key → SIGNER_ADDRESS, private key → used off-chain to sign on-chain writes)
cast wallet new
```

### Example filled-in .env

```bash
ARC_TESTNET_RPC_URL="https://testnet.arcscan.app/rpc"
DEPLOYER_PRIVATE_KEY="0xabc123..."

ORACLE_WITNESS_ADDRESS="0x_oracle_public_key"
SIGNER_ADDRESS="0x_signer_wallet"
PLATFORM_FEE_RECIPIENT="0x_my_treasury"
MARKET_FACTORY_PLATFORM_FEE_BPS="1000"

ETHERSCAN_API_KEY="your_arcscan_api_key"
```

Load the variables:

```shell
source .env
```

---

## 6. Deploy to Arc Testnet

The deployment script is at `script/Deploy.s.sol`. It deploys all 3 contracts in order and configures minter roles. The contracts use native Arc currency — no external token address is needed.

### Dry-run first (simulate without spending gas)

```shell
forge script script/Deploy.s.sol \
  --rpc-url arc_testnet \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

Review the output to confirm the deployment sequence:
1. `PublishingRightsNFT` deployed
2. `AuctionManager` deployed
3. `AuctionManager` granted minter role on NFT
4. `MarketFactory` deployed
5. `MarketFactory` granted minter role on NFT

### Broadcast (actual deployment)

```shell
forge script script/Deploy.s.sol \
  --rpc-url arc_testnet \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

Save the contract addresses printed in the console output:

```
--- Deployment Summary ---
PublishingRightsNFT: 0x...    ← OUTPUT  (PUBLISHING_RIGHTS_NFT_ADDRESS)
AuctionManager:      0x...    ← OUTPUT  (AUCTION_MANAGER_ADDRESS)
MarketFactory:       0x...    ← OUTPUT  (MARKET_FACTORY_ADDRESS)
Oracle witness:      0x...    ← INPUT   (ORACLE_WITNESS_ADDRESS — unchanged)
Signer:              0x...    ← INPUT   (SIGNER_ADDRESS — unchanged)
Platform recipient:  0x...    ← INPUT   (PLATFORM_FEE_RECIPIENT — unchanged)
```

---

## 7. Post-Deployment Verification

### Check NFT contract ownership

```shell
cast call <NFT_ADDRESS> "owner()(address)" --rpc-url arc_testnet
```

### Check minter whitelist

```shell
cast call <NFT_ADDRESS> "isMinter(address)(bool)" <AUCTION_MANAGER_ADDRESS> --rpc-url arc_testnet
cast call <NFT_ADDRESS> "isMinter(address)(bool)" <MARKET_FACTORY_ADDRESS> --rpc-url arc_testnet
```

Both should return `true`.

### Check AuctionManager configuration

```shell
cast call <AUCTION_MANAGER_ADDRESS> "oracleAddress()(address)" --rpc-url arc_testnet
cast call <AUCTION_MANAGER_ADDRESS> "backendAddress()(address)" --rpc-url arc_testnet
```

### Check MarketFactory configuration

```shell
cast call <MARKET_FACTORY_ADDRESS> "platformFeeBps()(uint256)" --rpc-url arc_testnet
cast call <MARKET_FACTORY_ADDRESS> "platformAddress()(address)" --rpc-url arc_testnet
```

---

## 8. Contract Verification on Etherscan

Verify all contracts for transparency and easier interaction via block explorer:

```shell
# Verify PublishingRightsNFT
forge verify-contract <NFT_ADDRESS> src/PublishingRightsNFT.sol:PublishingRightsNFT \
  --rpc-url arc_testnet \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cast abi-encode "constructor(string,string)" "PublishingRights" "PUBR")

# Verify AuctionManager
forge verify-contract <AUCTION_MANAGER_ADDRESS> src/AuctionManager.sol:AuctionManager \
  --rpc-url arc_testnet \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
    "$NFT_ADDRESS" "$ORACLE_WITNESS_ADDRESS" "$SIGNER_ADDRESS")

# Verify MarketFactory
forge verify-contract <MARKET_FACTORY_ADDRESS> src/MarketFactory.sol:MarketFactory \
  --rpc-url arc_testnet \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256)" \
    "$NFT_ADDRESS" "$ORACLE_WITNESS_ADDRESS" "$PLATFORM_FEE_RECIPIENT" "$MARKET_FACTORY_PLATFORM_FEE_BPS")
```

---

## 9. System Lifecycle

### Phase 1: Publishing Rights Auction

```
         Backend            Bidders             Anyone            Backend           Anyone
           │                   │                   │                  │                 │
           │ createAuction()   │                   │                  │                 │
           │──────────────────►│                   │                  │                 │
           │                   │                   │                  │                 │
           │                   │ placeBid() x N    │                  │                 │
           │                   │──────────────────►│                  │                 │
           │                   │                   │                  │                 │
           │                   │                   │ closeBidding()   │                 │
           │                   │                   │─────────────────►│                 │
           │                   │                   │                  │                 │
           │                   │                   │                  │ setShortlist()  │
           │                   │                   │                  │────────────────►│
           │                   │                   │                  │                 │
           │  (off-chain: experts evaluate finalists, backend signs winner with oracle key)
           │                   │                   │                  │                 │
           │                   │                   │                  │                 │ resolveAuction()
           │                   │                   │                  │                 │────────────────►
           │                   │                   │                  │                 │
           │  → NFT minted to winner. Non-winners call withdrawStake().
           │  → Owner calls withdrawWinningBids() to collect winner's stake.
```

#### Step-by-step with Cast

**1. Create an auction (backend only)**

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "createAuction(string,uint256,uint256)(uint256)" \
  "QHASH_news_item_001" 100000000 86400 \
  --rpc-url arc_testnet \
  --private-key "$BACKEND_PRIVATE_KEY"
```

- `"QHASH_news_item_001"` — question identifier
- `100000000` — minimum stake in wei (100 native Arc USDC, same as 100 USDC with 6 decimals)
- `86400` — bidding duration (1 day in seconds)

Returns the `auctionId`.

**2. Bidders place bids (send native value)**

```shell
# Place bid — send native value directly (no approve needed)
cast send <AUCTION_MANAGER_ADDRESS> \
  "placeBid(uint256,string)" \
  1 "ipfs://QmProposalHash" \
  --value 200000000 \
  --rpc-url arc_testnet \
  --private-key "$BIDDER_PRIVATE_KEY"
```

**3. Close bidding (anyone, after deadline)**

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "closeBidding(uint256)" 1 \
  --rpc-url arc_testnet \
  --private-key "$ANY_PRIVATE_KEY"
```

**4. Set shortlist (backend only, max 3 finalists)**

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "setShortlist(uint256,address[])" \
  1 "[0x_BIDDER1,0x_BIDDER2,0x_BIDDER3]" \
  --rpc-url arc_testnet \
  --private-key "$BACKEND_PRIVATE_KEY"
```

**5. Resolve auction (anyone with oracle signature)**

The oracle must sign off-chain: `keccak256(abi.encodePacked(auctionId, winner, winningScore))`

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "resolveAuction(uint256,address,uint256,string,bytes)" \
  1 <WINNER_ADDRESS> 9200 "ipfs://metadata" <ORACLE_SIGNATURE> \
  --rpc-url arc_testnet \
  --private-key "$ANY_PRIVATE_KEY"
```

**6. Non-winners withdraw**

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "withdrawStake(uint256)" 1 \
  --rpc-url arc_testnet \
  --private-key "$NON_WINNER_PRIVATE_KEY"
```

**7. Owner withdraws winning bids**

```shell
cast send <AUCTION_MANAGER_ADDRESS> \
  "withdrawWinningBids(address)" <OWNER_ADDRESS> \
  --rpc-url arc_testnet \
  --private-key "$OWNER_PRIVATE_KEY"
```

---

### Phase 2: Prediction Market

```
       NFT Holder              Bettors              Anyone              Anyone
           │                      │                    │                    │
           │ createMarket()       │                    │                    │
           │─────────────────────►│                    │                    │
           │                      │                    │                    │
           │                      │ placeBet() x N     │                    │
           │                      │───────────────────►│                    │
           │                      │                    │                    │
           │                      │                    │ closeBetting()     │
           │                      │                    │───────────────────►│
           │                      │                    │                    │
           │                      │                    │                    │ resolveMarket()
           │                      │                    │                    │─────────────────►
           │                      │                    │                    │
           │  → Winning bettors call claimWinnings().
           │  → Publisher calls nft.claimFees(tokenId) to collect their cut.
```

#### Step-by-step with Cast

**1. NFT holder creates a prediction market**

```shell
cast send <MARKET_FACTORY_ADDRESS> \
  "createMarket(uint256,string,string[],uint256,uint256)(address)" \
  1 "Will BTC break $100K in 2025?" '["Yes","No"]' 604800 500 \
  --rpc-url arc_testnet \
  --private-key "$PUBLISHER_PRIVATE_KEY"
```

- `1` — token ID of the publishing rights NFT
- `604800` — betting duration (7 days in seconds)
- `500` — publisher fee (5% = 500 bps)

Returns the `PredictionMarket` address. Save it.

**2. Bettors place bets (send native value)**

```shell
# Bet on option 0 ("Yes") — send native value directly (no approve needed)
cast send <MARKET_ADDRESS> \
  "placeBet(uint256)" \
  0 \
  --value 1000000000 \
  --rpc-url arc_testnet \
  --private-key "$BETTOR_PRIVATE_KEY"
```

**3. Close betting (anyone, after deadline)**

```shell
cast send <MARKET_ADDRESS> \
  "closeBetting()" \
  --rpc-url arc_testnet \
  --private-key "$ANY_PRIVATE_KEY"
```

**4. Resolve market (anyone with oracle signature)**

The oracle signs off-chain: `keccak256(abi.encodePacked(marketAddress, winningOptionIndex))`

```shell
cast send <MARKET_ADDRESS> \
  "resolveMarket(uint256,bytes)" \
  0 <ORACLE_SIGNATURE> \
  --rpc-url arc_testnet \
  --private-key "$ANY_PRIVATE_KEY"
```

**5. Winners claim payouts**

```shell
cast send <MARKET_ADDRESS> \
  "claimWinnings()" \
  --rpc-url arc_testnet \
  --private-key "$WINNER_PRIVATE_KEY"
```

**6. Publisher claims fees**

```shell
cast send <NFT_ADDRESS> \
  "claimFees(uint256)" 1 \
  --rpc-url arc_testnet \
  --private-key "$PUBLISHER_PRIVATE_KEY"
```

The NFT contract proxies the call to `PredictionMarket.claimPublisherFees()`, which sends:
- Platform's cut → `PLATFORM_FEE_RECIPIENT`
- Publisher's cut → NFT contract → forwarded to the NFT holder

---

## 10. Cast Interaction Cheat Sheet

### Read-only (view) calls

```shell
# Get auction details
cast call <AUCTION_MANAGER_ADDRESS> "getAuction(uint256)((address,string,uint256,uint256,uint8,address[],address[],address,uint256,uint256,bool))" 1 --rpc-url arc_testnet

# Get auction state
cast call <AUCTION_MANAGER_ADDRESS> "getAuctionState(uint256)(uint8)" 1 --rpc-url arc_testnet

# Get bidders list
cast call <AUCTION_MANAGER_ADDRESS> "getBidders(uint256)(address[])" 1 --rpc-url arc_testnet

# Get shortlist
cast call <AUCTION_MANAGER_ADDRESS> "getShortlist(uint256)(address[])" 1 --rpc-url arc_testnet

# Get bidder stake
cast call <AUCTION_MANAGER_ADDRESS> "getBidderStake(uint256,address)(uint256)" 1 <BIDDER_ADDRESS> --rpc-url arc_testnet

# Get market details
cast call <MARKET_ADDRESS> "getMarketDetails()(string,string[],uint256,uint256,uint256,uint8)" --rpc-url arc_testnet

# Get option pool amounts
cast call <MARKET_ADDRESS> "getOptionPoolAmounts()(uint256[])" --rpc-url arc_testnet

# Check claimable winnings
cast call <MARKET_ADDRESS> "getClaimableWinnings(address)(uint256)" <USER_ADDRESS> --rpc-url arc_testnet

# Check claimable publisher fees
cast call <MARKET_ADDRESS> "getClaimablePublisherFees()(uint256)" --rpc-url arc_testnet

# Get NFT owner
cast call <NFT_ADDRESS> "ownerOf(uint256)(address)" 1 --rpc-url arc_testnet

# Get tokens by owner
cast call <NFT_ADDRESS> "getTokensByOwner(address)(uint256[])" <OWNER_ADDRESS> --rpc-url arc_testnet
```

### Oracle signing (off-chain)

The oracle signs messages off-chain. Here's a Node.js / ethers.js example:

```javascript
const { ethers } = require("ethers");

const oracleKey = "0x_your_oracle_private_key";
const wallet = new ethers.Wallet(oracleKey);

// For AuctionManager resolution:
// message = keccak256(abi.encodePacked(auctionId, winner, winningScore))
const auctionId = 1;
const winner = "0x...";
const winningScore = 9200;
const messageHash = ethers.solidityPackedKeccak256(
    ["uint256", "address", "uint256"],
    [auctionId, winner, winningScore]
);
const signature = await wallet.signMessage(ethers.getBytes(messageHash));
console.log("Oracle signature:", signature);

// For PredictionMarket resolution:
// message = keccak256(abi.encodePacked(marketAddress, winningOptionIndex))
const marketAddr = "0x...";
const optionIndex = 0;
const marketHash = ethers.solidityPackedKeccak256(
    ["address", "uint256"],
    [marketAddr, optionIndex]
);
const marketSig = await wallet.signMessage(ethers.getBytes(marketHash));
console.log("Market signature:", marketSig);
```

### Admin operations

```shell
# Update oracle address (AuctionManager owner only)
cast send <AUCTION_MANAGER_ADDRESS> "setOracle(address)" <NEW_ORACLE> \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"

# Update backend address (AuctionManager owner only)
cast send <AUCTION_MANAGER_ADDRESS> "setBackend(address)" <NEW_BACKEND> \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"

# Update oracle on MarketFactory (owner only)
cast send <MARKET_FACTORY_ADDRESS> "setOracle(address)" <NEW_ORACLE> \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"

# Update platform fee on MarketFactory (owner only)
cast send <MARKET_FACTORY_ADDRESS> "setPlatformFee(uint256)" 500 \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"

# Update platform address on MarketFactory (owner only)
cast send <MARKET_FACTORY_ADDRESS> "setPlatform(address)" <NEW_PLATFORM> \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"

# Add minter to NFT (owner only)
cast send <NFT_ADDRESS> "addMinter(address)" <ADDRESS> \
  --rpc-url arc_testnet --private-key "$OWNER_PRIVATE_KEY"
```

---

## 11. Troubleshooting

| Problem | Solution |
|---|---|
| `forge build` fails with "Source not found" | Run `forge install` to download dependencies |
| `forge build` fails with solc version mismatch | The project uses Solidity `0.8.19`. Make sure Foundry has it: `foundryup` |
| "invalid signature" on resolve | Verify the oracle signed over the correct `abi.encodePacked` message (auctionId + winner + score, or marketAddress + optionIndex) |
| `NotNFTOwner` on createMarket | Only the current holder of the PublishingRightsNFT can create a market for that token |
| `MarketAlreadyExists` | One NFT can only have one active market at a time. Wait for current market to resolve. |
| `NotBackend` / `NotMinter` | Only the backend address can create auctions and set shortlists. Check `backendAddress()` on AuctionManager. |
| Gas estimation fails | Try increasing gas limit: `--gas-limit 5000000` |
| RPC connection issues | Verify `ARC_TESTNET_RPC_URL` in `.env`. Test with `cast chain-id --rpc-url arc_testnet` |
| Verification fails | Make sure `ETHERSCAN_API_KEY` is correct and the constructor args match exactly |
