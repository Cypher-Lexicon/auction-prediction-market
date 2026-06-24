// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/PublishingRightsNFT.sol";
import "../src/AuctionManager.sol";
import "../src/MarketFactory.sol";
import "../src/PredictionMarket.sol";
import "./helpers/SigUtils.sol";

contract PredictionMarketTest is Test, SigUtils {
    PublishingRightsNFT public nft;
    AuctionManager public auctionManager;
    MarketFactory public factory;
    PredictionMarket public market;

    address public owner = makeAddr("owner");
    address public backend = makeAddr("backend");
    address public publisher = makeAddr("publisher");
    address public bettor1 = makeAddr("bettor1");
    address public bettor2 = makeAddr("bettor2");
    address public bettor3 = makeAddr("bettor3");
    address public platform = makeAddr("platform");

    uint256 public oracleKey = 0xA11CE;
    address public oracle;

    uint256 public constant PLATFORM_FEE_BPS = 1000; // 10%
    uint256 public constant FEE_BPS = 500;            // 5%
    uint256 public constant BET_DURATION = 7 days;
    string[] public options = ["Yes", "No"];

    // NFT token that we'll create
    uint256 public tokenId;

    function setUp() public {
        oracle = vm.addr(oracleKey);

        vm.startPrank(owner);
        nft = new PublishingRightsNFT("PublishingRights", "PUBR");
        auctionManager = new AuctionManager(address(nft), oracle, backend);
        nft.addMinter(address(auctionManager));
        factory = new MarketFactory(address(nft), oracle, platform, PLATFORM_FEE_BPS);
        nft.addMinter(address(factory));
        vm.stopPrank();

        // Mint a publishing rights NFT to the publisher
        // We go through the auction flow to do this properly
        vm.prank(backend);
        uint256 auctionId = auctionManager.createAuction("QHASH", 100 * 1e6, 1 days);

        vm.deal(publisher, 1000 * 1e6);
        vm.prank(publisher);
        auctionManager.placeBid{value: 200 * 1e6}(auctionId, "proposal");

        // Also add another bidder so we can close
        address extraBidder = makeAddr("extra");
        vm.deal(extraBidder, 1000 * 1e6);
        vm.prank(extraBidder);
        auctionManager.placeBid{value: 100 * 1e6}(auctionId, "extra-proposal");

        vm.warp(block.timestamp + 2 days);
        auctionManager.closeBidding(auctionId);

        address[] memory finalists = new address[](1);
        finalists[0] = publisher;
        vm.prank(backend);
        auctionManager.setShortlist(auctionId, finalists);

        bytes memory sig = signAuctionResolution(auctionId, publisher, 9500, oracleKey);
        auctionManager.resolveAuction(auctionId, publisher, 9500, "ipfs://metadata", sig);

        tokenId = 1; // First token minted
        assertEq(nft.ownerOf(tokenId), publisher);

        // Fund bettors
        vm.deal(bettor1, 10000 * 1e6);
        vm.deal(bettor2, 10000 * 1e6);
        vm.deal(bettor3, 10000 * 1e6);
    }

    // ─── Market Creation ────────────────────────────────────────────────────

    function testCreateMarket() public {
        vm.prank(publisher);
        address marketAddr = factory.createMarket(
            tokenId, "Will it rain?", options, BET_DURATION, FEE_BPS
        );

        market = PredictionMarket(marketAddr);
        assertEq(market.tokenId(), tokenId);
        assertEq(market.getOptionCount(), 2);
        assertEq(uint256(market.getMarketState()), uint256(PredictionMarket.MarketState.BETTING_OPEN));
    }

    function testCreateMarketNotOwner() public {
        vm.prank(bettor1);
        vm.expectRevert(MarketFactory.NotNFTOwner.selector);
        factory.createMarket(tokenId, "Will it rain?", options, BET_DURATION, FEE_BPS);
    }

    function _createMarket() internal returns (PredictionMarket) {
        vm.prank(publisher);
        address marketAddr = factory.createMarket(
            tokenId, "Will it rain?", options, BET_DURATION, FEE_BPS
        );
        return PredictionMarket(marketAddr);
    }

    // ─── Betting ─────────────────────────────────────────────────────────────

    function testPlaceBet() public {
        market = _createMarket();

        uint256 betAmount = 1000 * 1e6; // 1000 native
        vm.prank(bettor1);
        market.placeBet{value: betAmount}(0);

        // 5% fee = 50 USDC
        uint256 expectedFee = (betAmount * FEE_BPS) / 10000;
        uint256 expectedBet = betAmount - expectedFee;

        assertEq(market.optionPoolAmounts(0), expectedBet);
        assertEq(market.totalBetPool(), expectedBet);
        assertEq(market.totalFeePool(), expectedFee);
        assertEq(market.userBetAmounts(bettor1, 0), expectedBet);
    }

    function testPlaceBetMultipleOptions() public {
        market = _createMarket();

        vm.prank(bettor1);
        market.placeBet{value: 1000 * 1e6}(0); // Bet on "Yes"

        vm.prank(bettor2);
        market.placeBet{value: 500 * 1e6}(1);  // Bet on "No"

        assertEq(market.optionPoolAmounts(0), 950 * 1e6);  // 1000 - 50
        assertEq(market.optionPoolAmounts(1), 475 * 1e6);  // 500 - 25
        assertEq(market.totalBetPool(), 1425 * 1e6);
        assertEq(market.totalFeePool(), 75 * 1e6);
    }

    function testPlaceBetInvalidOption() public {
        market = _createMarket();

        vm.prank(bettor1);
        vm.expectRevert(PredictionMarket.InvalidOptionIndex.selector);
        market.placeBet{value: 1000 * 1e6}(99);
    }

    function testPlaceBetZeroAmount() public {
        market = _createMarket();

        vm.prank(bettor1);
        vm.expectRevert(PredictionMarket.InvalidBetAmount.selector);
        market.placeBet{value: 0}(0);
    }

    function testPlaceBetAfterClose() public {
        market = _createMarket();

        vm.warp(block.timestamp + BET_DURATION + 1);

        vm.prank(bettor1);
        vm.expectRevert(PredictionMarket.BiddingClosed_.selector);
        market.placeBet{value: 1000 * 1e6}(0);
    }

    // ─── Closing ─────────────────────────────────────────────────────────────

    function testCloseBetting() public {
        market = _createMarket();

        vm.prank(bettor1);
        market.placeBet{value: 1000 * 1e6}(0);

        vm.warp(block.timestamp + BET_DURATION + 1);
        market.closeBetting();

        assertEq(
            uint256(market.getMarketState()),
            uint256(PredictionMarket.MarketState.BETTING_CLOSED)
        );
    }

    function testCloseBettingTooEarly() public {
        market = _createMarket();

        vm.expectRevert(PredictionMarket.BettingStillActive.selector);
        market.closeBetting();
    }

    // ─── Resolution ──────────────────────────────────────────────────────────

    function _setupBettingClosed() internal returns (PredictionMarket) {
        market = _createMarket();

        vm.prank(bettor1);
        market.placeBet{value: 1000 * 1e6}(0); // "Yes"

        vm.prank(bettor2);
        market.placeBet{value: 500 * 1e6}(1);  // "No"

        vm.warp(block.timestamp + BET_DURATION + 1);
        market.closeBetting();

        return market;
    }

    function testResolveMarket() public {
        market = _setupBettingClosed();

        bytes memory sig = signMarketResolution(address(market), 0, oracleKey);
        market.resolveMarket(0, sig);

        assertEq(
            uint256(market.getMarketState()),
            uint256(PredictionMarket.MarketState.RESOLVED)
        );
    }

    function testResolveMarketBadSignature() public {
        market = _setupBettingClosed();

        uint256 attackerKey = 0xB0B;
        bytes memory badSig = signMarketResolution(address(market), 0, attackerKey);

        vm.expectRevert(PredictionMarket.InvalidOracleSignature.selector);
        market.resolveMarket(0, badSig);
    }

    function testResolveMarketWrongAddress() public {
        market = _setupBettingClosed();

        // Sign for a different market address
        address wrongAddress = makeAddr("wrongMarket");
        bytes memory sig = signMarketResolution(wrongAddress, 0, oracleKey);

        vm.expectRevert(PredictionMarket.InvalidOracleSignature.selector);
        market.resolveMarket(0, sig);
    }

    // ─── Claiming Winnings ───────────────────────────────────────────────────

    function _setupResolved(uint256 winnerIdx) internal returns (PredictionMarket) {
        market = _setupBettingClosed();

        bytes memory sig = signMarketResolution(address(market), winnerIdx, oracleKey);
        market.resolveMarket(winnerIdx, sig);

        return market;
    }

    function testClaimWinnings() public {
        // "Yes" (option 0) wins. bettor1 bet 1000 on "Yes", bettor2 bet 500 on "No".
        market = _setupResolved(0);

        // bettor1 should get: 950 + (950 * 475) / 950 = 950 + 475 = 1425 USDC
        vm.prank(bettor1);
        uint256 claimed = market.claimWinnings();

        // bettor1's effective bet was 950 (1000 - 50 fee)
        // totalLosingBets = 475 (bettor2's effective bet on "No")
        // claimable = 950 + (950 * 475) / 950 = 950 + 475 = 1425
        assertEq(claimed, 1425 * 1e6);
    }

    function testClaimWinningsLoserCannotClaim() public {
        market = _setupResolved(0);

        vm.prank(bettor2); // bet on losing option
        vm.expectRevert(PredictionMarket.NothingToClaim.selector);
        market.claimWinnings();
    }

    function testClaimWinningsTwice() public {
        market = _setupResolved(0);

        vm.prank(bettor1);
        market.claimWinnings();

        vm.prank(bettor1);
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claimWinnings();
    }

    function testGetClaimableWinnings() public {
        market = _setupResolved(0);

        uint256 claimable = market.getClaimableWinnings(bettor1);
        assertEq(claimable, 1425 * 1e6);

        uint256 loserClaimable = market.getClaimableWinnings(bettor2);
        assertEq(loserClaimable, 0);
    }

    // ─── Publisher Fees ──────────────────────────────────────────────────────

    function testClaimPublisherFeesViaNFTContract() public {
        market = _setupResolved(0);

        // totalFeePool from bets: (1000 * 5%) + (500 * 5%) = 50 + 25 = 75 USDC
        assertEq(market.totalFeePool(), 75 * 1e6);

        // Call as the NFT contract (simulating the proxy flow)
        vm.prank(address(nft));
        market.claimPublisherFees();

        uint256 platformCut = (75 * 1e6 * PLATFORM_FEE_BPS) / 10000; // 10% of 75 = 7.5
        uint256 publisherCut = 75 * 1e6 - platformCut;

        assertEq(platform.balance, platformCut);
        assertEq(address(nft).balance, publisherCut);
    }

    function testClaimPublisherFeesNotNFTContract() public {
        market = _setupResolved(0);

        vm.prank(bettor1);
        vm.expectRevert(PredictionMarket.NotNFTOwner.selector);
        market.claimPublisherFees();
    }

    function testClaimPublisherFeesViaNFTProxy() public {
        market = _setupResolved(0);

        // The NFT contract's claimFees should work for the publisher
        uint256 publisherBalanceBefore = publisher.balance;

        vm.prank(publisher);
        nft.claimFees(tokenId);

        uint256 publisherBalanceAfter = publisher.balance;
        assertGt(publisherBalanceAfter, publisherBalanceBefore);
    }

    // ─── Full Integration ────────────────────────────────────────────────────

    function testFullPredictionMarketLifecycle() public {
        // Create market
        vm.prank(publisher);
        address marketAddr = factory.createMarket(
            tokenId, "Will ETH break $5000?", options, BET_DURATION, FEE_BPS
        );
        market = PredictionMarket(marketAddr);

        // Users bet
        vm.prank(bettor1);
        market.placeBet{value: 2000 * 1e6}(0); // "Yes"

        vm.prank(bettor2);
        market.placeBet{value: 800 * 1e6}(1);  // "No"

        vm.prank(bettor3);
        market.placeBet{value: 300 * 1e6}(0);  // "Yes"

        // Close
        vm.warp(block.timestamp + BET_DURATION + 1);
        market.closeBetting();

        // Resolve: "Yes" wins
        bytes memory sig = signMarketResolution(address(market), 0, oracleKey);
        market.resolveMarket(0, sig);

        // Winning bettors claim
        vm.prank(bettor1);
        market.claimWinnings();
        vm.prank(bettor3);
        market.claimWinnings();

        // Publisher claims fees
        vm.prank(publisher);
        nft.claimFees(tokenId);

        // Verify publisher received fees
        // total fees = (2000+800+300) * 5% = 155 USDC
        // platform cut = 155 * 10% = 15.5
        // publisher cut = 155 - 15.5 = 139.5 USDC
        assertEq(market.totalFeePool(), 0);
        assertTrue(publisher.balance > 0);
    }
}
