// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/PublishingRightsNFT.sol";
import "../src/AuctionManager.sol";
import "./helpers/MockUSDC.sol";
import "./helpers/SigUtils.sol";

contract AuctionManagerTest is Test, SigUtils {
    PublishingRightsNFT public nft;
    AuctionManager public auctionManager;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public backend = makeAddr("backend");
    address public bidder1 = makeAddr("bidder1");
    address public bidder2 = makeAddr("bidder2");
    address public bidder3 = makeAddr("bidder3");
    address public bidder4 = makeAddr("bidder4");
    address public nonBidder = makeAddr("nonBidder");

    // Oracle: we need the address from a known private key
    uint256 public oracleKey = 0xA11CE;
    address public oracle;

    uint256 public constant MINIMUM_STAKE = 100 * 1e6; // 100 USDC
    uint256 public constant BID_DURATION = 1 days;

    function setUp() public {
        oracle = vm.addr(oracleKey);

        vm.startPrank(owner);
        usdc = new MockUSDC();
        nft = new PublishingRightsNFT("PublishingRights", "PUBR", address(usdc));
        auctionManager = new AuctionManager(
            address(nft),
            address(usdc),
            oracle,
            backend
        );
        nft.addMinter(address(auctionManager));
        vm.stopPrank();

        // Fund bidders with USDC
        usdc.mint(bidder1, 10000 * 1e6);
        usdc.mint(bidder2, 10000 * 1e6);
        usdc.mint(bidder3, 10000 * 1e6);
        usdc.mint(bidder4, 10000 * 1e6);
    }

    // ─── Constructor & Admin ────────────────────────────────────────────────

    function testConstructor() public {
        assertEq(address(auctionManager.usdc()), address(usdc));
        assertEq(address(auctionManager.nftContract()), address(nft));
        assertEq(auctionManager.oracleAddress(), oracle);
        assertEq(auctionManager.backendAddress(), backend);
        assertEq(auctionManager.auctionCount(), 0);
    }

    function testSetOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(owner);
        auctionManager.setOracle(newOracle);
        assertEq(auctionManager.oracleAddress(), newOracle);
    }

    function testSetOracleNotOwner() public {
        vm.prank(bidder1);
        vm.expectRevert("Ownable: caller is not the owner");
        auctionManager.setOracle(makeAddr("newOracle"));
    }

    function testSetBackend() public {
        address newBackend = makeAddr("newBackend");
        vm.prank(owner);
        auctionManager.setBackend(newBackend);
        assertEq(auctionManager.backendAddress(), newBackend);
    }

    // ─── Auction Creation ───────────────────────────────────────────────────

    function testCreateAuction() public {
        vm.prank(backend);
        uint256 auctionId = auctionManager.createAuction("QHASH_001", MINIMUM_STAKE, BID_DURATION);

        assertEq(auctionId, 1);
        assertEq(auctionManager.auctionCount(), 1);
        assertEq(
            uint256(auctionManager.getAuctionState(1)),
            uint256(AuctionManager.AuctionState.BIDDING_OPEN)
        );
    }

    function testCreateAuctionNotBackend() public {
        vm.prank(bidder1);
        vm.expectRevert(AuctionManager.NotBackend.selector);
        auctionManager.createAuction("QHASH_001", MINIMUM_STAKE, BID_DURATION);
    }

    function testCreateAuctionEmptyQuestion() public {
        vm.prank(backend);
        vm.expectRevert("Question hash empty");
        auctionManager.createAuction("", MINIMUM_STAKE, BID_DURATION);
    }

    function testCreateAuctionZeroDuration() public {
        vm.prank(backend);
        vm.expectRevert("Duration must be > 0");
        auctionManager.createAuction("QHASH_001", MINIMUM_STAKE, 0);
    }

    // ─── Bidding ─────────────────────────────────────────────────────────────

    function _createAuction() internal returns (uint256) {
        vm.prank(backend);
        return auctionManager.createAuction("QHASH_001", MINIMUM_STAKE, BID_DURATION);
    }

    function testPlaceBid() public {
        uint256 auctionId = _createAuction();

        uint256 stake = 200 * 1e6;
        vm.prank(bidder1);
        usdc.approve(address(auctionManager), stake);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, stake, "ipfs://proposal1");

        assertEq(auctionManager.bidderStakes(auctionId, bidder1), stake);

        string memory proposal = auctionManager.getBidderProposal(auctionId, bidder1);
        assertEq(proposal, "ipfs://proposal1");
    }

    function testPlaceBidAdditive() public {
        uint256 auctionId = _createAuction();

        vm.startPrank(bidder1);
        usdc.approve(address(auctionManager), 500 * 1e6);
        auctionManager.placeBid(auctionId, 200 * 1e6, "ipfs://proposal1");
        auctionManager.placeBid(auctionId, 100 * 1e6, "ipfs://proposal1v2");
        vm.stopPrank();

        assertEq(auctionManager.bidderStakes(auctionId, bidder1), 300 * 1e6);
    }

    function testPlaceBidBelowMinimum() public {
        uint256 auctionId = _createAuction();

        vm.prank(bidder1);
        usdc.approve(address(auctionManager), 50 * 1e6);
        vm.prank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionManager.StakeTooLow.selector, MINIMUM_STAKE, 50 * 1e6)
        );
        auctionManager.placeBid(auctionId, 50 * 1e6, "proposal");
    }

    function testPlaceBidAfterEnd() public {
        uint256 auctionId = _createAuction();

        vm.warp(block.timestamp + BID_DURATION + 1);

        vm.prank(bidder1);
        usdc.approve(address(auctionManager), MINIMUM_STAKE);
        vm.prank(bidder1);
        vm.expectRevert(AuctionManager.BiddingNotOpen.selector);
        auctionManager.placeBid(auctionId, MINIMUM_STAKE, "proposal");
    }

    function testMultipleBidders() public {
        uint256 auctionId = _createAuction();

        vm.prank(bidder1);
        usdc.approve(address(auctionManager), 200 * 1e6);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, 200 * 1e6, "proposal1");

        vm.prank(bidder2);
        usdc.approve(address(auctionManager), 300 * 1e6);
        vm.prank(bidder2);
        auctionManager.placeBid(auctionId, 300 * 1e6, "proposal2");

        vm.prank(bidder3);
        usdc.approve(address(auctionManager), 150 * 1e6);
        vm.prank(bidder3);
        auctionManager.placeBid(auctionId, 150 * 1e6, "proposal3");

        address[] memory bidders = auctionManager.getBidders(auctionId);
        assertEq(bidders.length, 3);
    }

    // ─── Close Bidding ──────────────────────────────────────────────────────

    function testCloseBidding() public {
        uint256 auctionId = _createAuction();

        vm.prank(bidder1);
        usdc.approve(address(auctionManager), MINIMUM_STAKE);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, MINIMUM_STAKE, "proposal1");

        vm.warp(block.timestamp + BID_DURATION + 1);

        vm.prank(bidder2);
        auctionManager.closeBidding(auctionId);

        assertEq(
            uint256(auctionManager.getAuctionState(auctionId)),
            uint256(AuctionManager.AuctionState.BIDDING_CLOSED)
        );
    }

    function testCloseBiddingTooEarly() public {
        uint256 auctionId = _createAuction();

        vm.prank(bidder1);
        usdc.approve(address(auctionManager), MINIMUM_STAKE);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, MINIMUM_STAKE, "proposal1");

        vm.prank(bidder2);
        vm.expectRevert(AuctionManager.BiddingNotOpen.selector);
        auctionManager.closeBidding(auctionId);
    }

    function testCloseBiddingNoBids() public {
        uint256 auctionId = _createAuction();
        vm.warp(block.timestamp + BID_DURATION + 1);

        vm.expectRevert(AuctionManager.NoBidsPlaced.selector);
        auctionManager.closeBidding(auctionId);
    }

    // ─── Shortlist ──────────────────────────────────────────────────────────

    function _setupBiddingClosed(uint256 auctionId) internal {
        vm.prank(bidder1);
        usdc.approve(address(auctionManager), 200 * 1e6);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, 200 * 1e6, "proposal1");

        vm.prank(bidder2);
        usdc.approve(address(auctionManager), 300 * 1e6);
        vm.prank(bidder2);
        auctionManager.placeBid(auctionId, 300 * 1e6, "proposal2");

        vm.prank(bidder3);
        usdc.approve(address(auctionManager), 150 * 1e6);
        vm.prank(bidder3);
        auctionManager.placeBid(auctionId, 150 * 1e6, "proposal3");

        vm.warp(block.timestamp + BID_DURATION + 1);
        auctionManager.closeBidding(auctionId);
    }

    function testSetShortlist() public {
        uint256 auctionId = _createAuction();
        _setupBiddingClosed(auctionId);

        address[] memory finalists = new address[](2);
        finalists[0] = bidder1;
        finalists[1] = bidder3;

        vm.prank(backend);
        auctionManager.setShortlist(auctionId, finalists);

        assertEq(
            uint256(auctionManager.getAuctionState(auctionId)),
            uint256(AuctionManager.AuctionState.SHORTLIST_SET)
        );
        assertTrue(auctionManager.isShortlisted(auctionId, bidder1));
        assertTrue(auctionManager.isShortlisted(auctionId, bidder3));
        assertFalse(auctionManager.isShortlisted(auctionId, bidder2));

        address[] memory shortlist = auctionManager.getShortlist(auctionId);
        assertEq(shortlist.length, 2);
        assertEq(shortlist[0], bidder1);
        assertEq(shortlist[1], bidder3);
    }

    function testSetShortlistNotBackend() public {
        uint256 auctionId = _createAuction();
        _setupBiddingClosed(auctionId);

        address[] memory finalists = new address[](1);
        finalists[0] = bidder1;

        vm.prank(bidder1);
        vm.expectRevert(AuctionManager.NotBackend.selector);
        auctionManager.setShortlist(auctionId, finalists);
    }

    function testSetShortlistTooMany() public {
        uint256 auctionId = _createAuction();
        _setupBiddingClosed(auctionId);

        address[] memory finalists = new address[](4);
        finalists[0] = bidder1;
        finalists[1] = bidder2;
        finalists[2] = bidder3;
        finalists[3] = bidder4;

        vm.prank(backend);
        vm.expectRevert("Max 3 finalists");
        auctionManager.setShortlist(auctionId, finalists);
    }

    function testSetShortlistNonBidder() public {
        uint256 auctionId = _createAuction();
        _setupBiddingClosed(auctionId);

        address[] memory finalists = new address[](1);
        finalists[0] = nonBidder;

        vm.prank(backend);
        vm.expectRevert("Finalist not a bidder");
        auctionManager.setShortlist(auctionId, finalists);
    }

    // ─── Resolution (ECDSA Oracle Signature) ─────────────────────────────────

    function _setupShortlistSet(uint256 auctionId) internal {
        _setupBiddingClosed(auctionId);

        address[] memory finalists = new address[](2);
        finalists[0] = bidder1;
        finalists[1] = bidder2;

        vm.prank(backend);
        auctionManager.setShortlist(auctionId, finalists);
    }

    function testResolveAuction() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        uint256 winningScore = 9200; // out of 10000

        bytes memory sig = signAuctionResolution(auctionId, bidder1, winningScore, oracleKey);

        auctionManager.resolveAuction(auctionId, bidder1, winningScore, "ipfs://nft-metadata", sig);

        assertEq(
            uint256(auctionManager.getAuctionState(auctionId)),
            uint256(AuctionManager.AuctionState.COMPLETED)
        );

        // Winner should own the NFT
        assertEq(nft.ownerOf(1), bidder1);

        AuctionManager.Auction memory a = auctionManager.getAuction(auctionId);
        assertEq(a.winner, bidder1);
        assertEq(a.winningScore, winningScore);
        assertTrue(a.winnerDeclared);
        assertEq(a.nftTokenId, 1);
    }

    function testResolveAuctionBadSignature() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        // Use someone else's key to sign (not oracle)
        uint256 attackerKey = 0xB0B;
        bytes memory badSig = signAuctionResolution(auctionId, bidder1, 9200, attackerKey);

        vm.expectRevert(AuctionManager.InvalidOracleSignature.selector);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", badSig);
    }

    function testResolveAuctionWrongMessage() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        // Sign a different message (different auctionId)
        bytes memory sig = signAuctionResolution(auctionId + 1, bidder1, 9200, oracleKey);

        vm.expectRevert(AuctionManager.InvalidOracleSignature.selector);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);
    }

    function testResolveAuctionWinnerNotShortlisted() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder3, 9200, oracleKey);

        vm.expectRevert(AuctionManager.WinnerNotShortlisted.selector);
        auctionManager.resolveAuction(auctionId, bidder3, 9200, "metadata", sig);
    }

    function testCannotResolveTwice() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        vm.expectRevert(
            abi.encodeWithSelector(
                AuctionManager.InvalidState.selector,
                AuctionManager.AuctionState.COMPLETED,
                AuctionManager.AuctionState.SHORTLIST_SET
            )
        );
        auctionManager.resolveAuction(auctionId, bidder2, 8500, "metadata2", sig);
    }

    // ─── Withdrawals ────────────────────────────────────────────────────────

    function testWithdrawStake() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        // bidder2 (non-winner, shortlisted) should be able to withdraw
        uint256 balanceBefore = usdc.balanceOf(bidder2);
        vm.prank(bidder2);
        auctionManager.withdrawStake(auctionId);
        uint256 balanceAfter = usdc.balanceOf(bidder2);

        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, 300 * 1e6); // bidder2 staked 300
    }

    function testWinnerCannotWithdrawStake() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        vm.prank(bidder1);
        vm.expectRevert(AuctionManager.NothingToWithdraw.selector);
        auctionManager.withdrawStake(auctionId);
    }

    function testCannotWithdrawTwice() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        vm.prank(bidder2);
        auctionManager.withdrawStake(auctionId);

        vm.prank(bidder2);
        vm.expectRevert(AuctionManager.WithdrawAlreadyClaimed.selector);
        auctionManager.withdrawStake(auctionId);
    }

    function testWinningBidsAccumulate() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        // Winner's stake goes to accumulatedWinningBids
        assertEq(auctionManager.accumulatedWinningBids(), 200 * 1e6); // bidder1 staked 200
    }

    function testOwnerWithdrawWinningBids() public {
        uint256 auctionId = _createAuction();
        _setupShortlistSet(auctionId);

        bytes memory sig = signAuctionResolution(auctionId, bidder1, 9200, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder1, 9200, "metadata", sig);

        uint256 balanceBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        auctionManager.withdrawWinningBids(owner);
        uint256 balanceAfter = usdc.balanceOf(owner);

        assertEq(balanceAfter - balanceBefore, 200 * 1e6);
        assertEq(auctionManager.accumulatedWinningBids(), 0);
    }

    // ─── Full Lifecycle ─────────────────────────────────────────────────────

    function testFullLifecycle() public {
        // 1. Create auction
        vm.prank(backend);
        uint256 auctionId = auctionManager.createAuction("QHASH_001", MINIMUM_STAKE, BID_DURATION);

        // 2. Bidders submit
        vm.prank(bidder1);
        usdc.approve(address(auctionManager), 200 * 1e6);
        vm.prank(bidder1);
        auctionManager.placeBid(auctionId, 200 * 1e6, "ipfs://proposal1");

        vm.prank(bidder2);
        usdc.approve(address(auctionManager), 300 * 1e6);
        vm.prank(bidder2);
        auctionManager.placeBid(auctionId, 300 * 1e6, "ipfs://proposal2");

        vm.prank(bidder3);
        usdc.approve(address(auctionManager), 150 * 1e6);
        vm.prank(bidder3);
        auctionManager.placeBid(auctionId, 150 * 1e6, "ipfs://proposal3");

        // 3. Close bidding
        vm.warp(block.timestamp + BID_DURATION + 1);
        auctionManager.closeBidding(auctionId);

        // 4. Set shortlist
        address[] memory finalists = new address[](2);
        finalists[0] = bidder2;
        finalists[1] = bidder1;
        vm.prank(backend);
        auctionManager.setShortlist(auctionId, finalists);

        // 5. Resolve (oracle signs bidder2 as winner)
        bytes memory sig = signAuctionResolution(auctionId, bidder2, 9500, oracleKey);
        auctionManager.resolveAuction(auctionId, bidder2, 9500, "ipfs://metadata-winner", sig);

        // 6. Winner owns NFT
        assertEq(nft.ownerOf(1), bidder2);

        // 7. Non-winners withdraw
        vm.prank(bidder1);
        auctionManager.withdrawStake(auctionId);
        vm.prank(bidder3);
        auctionManager.withdrawStake(auctionId);

        // 8. Owner withdraws winning bids
        vm.prank(owner);
        auctionManager.withdrawWinningBids(owner);

        // Verify final state
        assertEq(
            uint256(auctionManager.getAuctionState(auctionId)),
            uint256(AuctionManager.AuctionState.COMPLETED)
        );
    }
}
