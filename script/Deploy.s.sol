// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/PublishingRightsNFT.sol";
import "../src/AuctionManager.sol";
import "../src/MarketFactory.sol";

/**
 * @title Deploy
 * @notice Deploys all Prediction Market Auction contracts to Arc Testnet.
 *
 * The system uses the native Arc currency for all application flows.
 *
 * For local development on Anvil, use forge test which handles funding automatically.
 *
 * Usage:
 *   source .env
 *   forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        // ─── Configuration (INPUTS — set in .env before deploying) ──────────
        address oracleWitness = vm.envAddress("ORACLE_WITNESS_ADDRESS");
        address signer = vm.envAddress("SIGNER_ADDRESS");
        address platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");
        uint256 marketFactoryPlatformFeeBps = vm.envUint("MARKET_FACTORY_PLATFORM_FEE_BPS");

        // ─── Deploy ──────────────────────────────────────────────────────────

        vm.startBroadcast();

        // 1. Deploy PublishingRightsNFT
        PublishingRightsNFT nft = new PublishingRightsNFT(
            "PublishingRights",
            "PUBR"
        );
        console.log("PublishingRightsNFT deployed at:", address(nft));

        // 2. Deploy AuctionManager
        AuctionManager auctionManager = new AuctionManager(
            address(nft),
            oracleWitness,
            signer
        );
        console.log("AuctionManager deployed at:", address(auctionManager));

        // 3. Grant AuctionManager minter role on NFT
        nft.addMinter(address(auctionManager));
        console.log("AuctionManager added as minter");

        // 4. Deploy MarketFactory
        MarketFactory factory = new MarketFactory(
            address(nft),
            oracleWitness,
            platformFeeRecipient,
            marketFactoryPlatformFeeBps
        );
        console.log("MarketFactory deployed at:", address(factory));

        // 5. Grant MarketFactory minter role on NFT
        nft.addMinter(address(factory));
        console.log("MarketFactory added as minter");

        vm.stopBroadcast();

        console.log("\n--- Deployment Summary ---");
        console.log("PublishingRightsNFT:", address(nft));
        console.log("AuctionManager:     ", address(auctionManager));
        console.log("MarketFactory:      ", address(factory));
        console.log("Oracle witness:     ", oracleWitness);
        console.log("Signer:             ", signer);
        console.log("Platform recipient: ", platformFeeRecipient);
    }
}
