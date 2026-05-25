// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/PublishingRightsNFT.sol";
import "../src/AuctionManager.sol";
import "../src/MarketFactory.sol";
import "../test/helpers/MockUSDC.sol";

/**
 * @title Deploy
 * @notice Deploys all Prediction Market Auction contracts to Arc Testnet.
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

        // 0. Deploy mock USDC token (6 decimals, used as currency for the system)
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // Mint initial supply to deployer (for testing / funding bidders & bettors)
        usdc.mint(msg.sender, 1_000_000_000_000_000); // 1B USDC

        // 1. Deploy PublishingRightsNFT
        PublishingRightsNFT nft = new PublishingRightsNFT(
            "PublishingRights",
            "PUBR",
            address(usdc)
        );
        console.log("PublishingRightsNFT deployed at:", address(nft));

        // 2. Deploy AuctionManager
        AuctionManager auctionManager = new AuctionManager(
            address(nft),
            address(usdc),
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
            address(usdc),
            oracleWitness,
            platformFeeRecipient,
            marketFactoryPlatformFeeBps
        );
        console.log("MarketFactory deployed at:", address(factory));

        // 5. Grant MarketFactory minter role on NFT
        nft.addMinter(address(factory));
        console.log("MarketFactory added as minter");

        // 6. Transfer NFT ownership to deployer (already owned by deployer)
        //    or optionally transfer to a governance address.
        // nft.transferOwnership(governanceAddress);

        vm.stopBroadcast();

        console.log("\n--- Deployment Summary ---");
        console.log("MockUSDC:            ", address(usdc));
        console.log("PublishingRightsNFT:", address(nft));
        console.log("AuctionManager:     ", address(auctionManager));
        console.log("MarketFactory:      ", address(factory));
        console.log("Oracle witness:     ", oracleWitness);
        console.log("Signer:             ", signer);
        console.log("Platform recipient: ", platformFeeRecipient);
    }
}
