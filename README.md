# Auction Prediction Market

Smart contracts for a prediction market built on auction-based mechanics.

## Prerequisites

-   [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Setup

Clone the repository and install dependencies:

```shell
git clone --recurse-submodules <repo-url>
cd auction-prediction-market
forge install
```

If you cloned without `--recurse-submodules`, run:

```shell
forge install
```

`forge install` reads `.gitmodules` (like `requirements.txt`) and downloads
the Solidity dependencies (`forge-std`, `openzeppelin-contracts`) into `lib/`.

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Deploy

```shell
forge script script/Deploy.s.sol --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Help

```shell
forge --help
anvil --help
cast --help
```
