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
 * Usage:
 *   source .env
 *   forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        // ─── Configuration ───────────────────────────────────────────────────
        address usdcToken = vm.envAddress("USDC_ADDRESS");
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address backendAddress = vm.envAddress("BACKEND_ADDRESS");
        address platformAddress = vm.envAddress("PLATFORM_ADDRESS");
        uint256 platformFeeBps = vm.envUint("PLATFORM_FEE_BPS");

        // ─── Deploy ──────────────────────────────────────────────────────────

        vm.startBroadcast();

        // 1. Deploy PublishingRightsNFT
        PublishingRightsNFT nft = new PublishingRightsNFT(
            "PublishingRights",
            "PUBR",
            usdcToken
        );
        console.log("PublishingRightsNFT deployed at:", address(nft));

        // 2. Deploy AuctionManager
        AuctionManager auctionManager = new AuctionManager(
            address(nft),
            usdcToken,
            oracleAddress,
            backendAddress
        );
        console.log("AuctionManager deployed at:", address(auctionManager));

        // 3. Grant AuctionManager minter role on NFT
        nft.addMinter(address(auctionManager));
        console.log("AuctionManager added as minter");

        // 4. Deploy MarketFactory
        MarketFactory factory = new MarketFactory(
            address(nft),
            usdcToken,
            oracleAddress,
            platformAddress,
            platformFeeBps
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
        console.log("PublishingRightsNFT:", address(nft));
        console.log("AuctionManager:     ", address(auctionManager));
        console.log("MarketFactory:      ", address(factory));
        console.log("USDC:               ", usdcToken);
        console.log("Oracle:             ", oracleAddress);
        console.log("Backend:            ", backendAddress);
    }
}
