// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/PublishingRightsNFT.sol";
import "./helpers/MockUSDC.sol";

contract PublishingRightsNFTTest is Test {
    PublishingRightsNFT public nft;
    MockUSDC public usdc;

    address public owner = address(1);
    address public minter = address(2);
    address public user = address(3);
    address public user2 = address(4);

    function setUp() public {
        vm.prank(owner);
        usdc = new MockUSDC();
        vm.prank(owner);
        nft = new PublishingRightsNFT("PublishingRights", "PUBR", address(usdc));
    }

    // ─── Constructor & Minting ──────────────────────────────────────────────

    function testConstructor() public {
        assertEq(nft.name(), "PublishingRights");
        assertEq(nft.symbol(), "PUBR");
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.nextTokenId(), 1);
    }

    function testMint() public {
        vm.prank(owner);
        nft.addMinter(minter);

        vm.prank(minter);
        uint256 tokenId = nft.mint(user, 1, "ipfs://metadata");

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), user);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.nextTokenId(), 2);

        (uint256 auctionId, string memory uri, address market, bool active) = nft.tokenInfo(1);
        assertEq(auctionId, 1);
        assertEq(uri, "ipfs://metadata");
        assertEq(market, address(0));
        assertFalse(active);
    }

    function testMintBatchTokens() public {
        vm.prank(owner);
        nft.addMinter(minter);

        vm.startPrank(minter);
        nft.mint(user, 1, "uri1");
        nft.mint(user2, 2, "uri2");
        nft.mint(user, 3, "uri3");
        vm.stopPrank();

        assertEq(nft.totalSupply(), 3);

        uint256[] memory userTokens = nft.getTokensByOwner(user);
        assertEq(userTokens.length, 2);
        assertEq(userTokens[0], 1);
        assertEq(userTokens[1], 3);
    }

    function testMintOnlyMinter() public {
        vm.prank(user);
        vm.expectRevert(PublishingRightsNFT.NotMinter.selector);
        nft.mint(user, 1, "uri");
    }

    // ─── Minter Management ──────────────────────────────────────────────────

    function testAddMinter() public {
        vm.prank(owner);
        nft.addMinter(minter);
        assertTrue(nft.isMinter(minter));
    }

    function testAddMinterNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.addMinter(minter);
    }

    function testRemoveMinter() public {
        vm.prank(owner);
        nft.addMinter(minter);
        assertTrue(nft.isMinter(minter));

        vm.prank(owner);
        nft.removeMinter(minter);
        assertFalse(nft.isMinter(minter));
    }

    // ─── Market Linking ─────────────────────────────────────────────────────

    function testSetMarketAddress() public {
        vm.prank(owner);
        nft.addMinter(minter);

        vm.prank(minter);
        nft.mint(user, 1, "uri");

        address market = address(0xABCD);

        vm.prank(minter);
        nft.setMarketAddress(1, market);

        (, , address storedMarket, bool active) = nft.tokenInfo(1);
        assertEq(storedMarket, market);
        assertTrue(active);
    }

    function testSetMarketAddressNotMinter() public {
        vm.prank(owner);
        nft.addMinter(minter);
        vm.prank(minter);
        nft.mint(user, 1, "uri");

        vm.prank(user);
        vm.expectRevert(PublishingRightsNFT.NotMinter.selector);
        nft.setMarketAddress(1, address(0xABCD));
    }

    function testClearMarketActive() public {
        vm.prank(owner);
        nft.addMinter(minter);
        vm.prank(minter);
        nft.mint(user, 1, "uri");

        address market = address(0xABCD);
        vm.prank(minter);
        nft.setMarketAddress(1, market);

        vm.prank(minter);
        nft.clearMarketActive(1);

        (, , , bool active) = nft.tokenInfo(1);
        assertFalse(active);
    }

    // ─── Token Transfer ────────────────────────────────────────────────────

    function testTokenTransfer() public {
        vm.prank(owner);
        nft.addMinter(minter);
        vm.prank(minter);
        nft.mint(user, 1, "uri");

        vm.prank(user);
        nft.transferFrom(user, user2, 1);

        assertEq(nft.ownerOf(1), user2);
        assertEq(nft.getTokensByOwner(user).length, 0);
        assertEq(nft.getTokensByOwner(user2).length, 1);
    }
}
