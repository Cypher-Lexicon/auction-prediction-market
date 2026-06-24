// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./PublishingRightsNFT.sol";

/**
 * @title AuctionManager
 * @notice Phase 1: Translation Rights Auction with expert evaluation.
 *
 * Lifecycle:
 *   BIDDING_OPEN → BIDDING_CLOSED → SHORTLIST_SET → COMPLETED
 *
 * 1. Users stake native currency and submit a proposal hash to bid for publishing rights.
 * 2. After bidding closes, the off-chain backend runs AI filtering and
 *    deterministic scoring to produce a shortlist of ≤3 finalists.
 * 3. Experts evaluate finalists off-chain. The backend computes the median
 *    score and the oracle signs the winner.
 * 4. Anyone submits the oracle-signed result. The contract verifies the
 *    ECDSA signature, mints an ERC-721 PublishingRightsNFT to the winner,
 *    and transitions to COMPLETED.
 *
 * Non-winners can withdraw their staked native currency. The winner's stake
 * stays in the contract as payment for the publishing rights.
 */
contract AuctionManager is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // ─── Types ───────────────────────────────────────────────────────────────

    enum AuctionState {
        INACTIVE,
        BIDDING_OPEN,
        BIDDING_CLOSED,
        SHORTLIST_SET,
        COMPLETED
    }

    struct Auction {
        address creator;
        string questionHash;
        uint256 minimumStake;
        uint256 biddingEndTime;
        AuctionState state;
        address[] bidders;
        address[] shortlist;
        address winner;
        uint256 winningScore;
        uint256 nftTokenId;
        bool winnerDeclared;
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    PublishingRightsNFT public immutable nftContract;

    /// @notice Oracle witness address for ECDSA signature verification.
    /// @dev This is a regular Ethereum wallet address (0x...), NOT a URL or
    /// contract. The oracle is a WITNESS — its matching private key signs
    /// attestations off-chain (auctionId, winner, winningScore). The oracle
    /// never sends on-chain transactions. Anyone can relay the signed
    /// attestation; the contract verifies it against this public key via
    /// ecrecover(). This address is the reference point of trust.
    address public oracleAddress;

    /// @notice Signer wallet — its private key (held off-chain) authorizes on-chain
    /// writes. The contract checks msg.sender == this address to verify that
    /// createAuction() and setShortlist() calls originate from the authorized backend.
    /// @dev This is a regular Ethereum wallet address (0x...), NOT a URL or
    /// contract. The private key lives off-chain with the backend server.
    /// Generate one with: cast wallet new
    address public backendAddress;

    uint256 private _auctionCounter;

    mapping(uint256 => Auction) private _auctions;
    mapping(uint256 => mapping(address => uint256)) public bidderStakes;
    mapping(uint256 => mapping(address => string)) public bidderProposals;
    mapping(uint256 => mapping(address => bool)) public isShortlisted;
    mapping(uint256 => mapping(address => bool)) public stakeWithdrawn;

    /// @notice Admin-only withdrawal of accumulated winning bids.
    uint256 public accumulatedWinningBids;

    // ─── Events ──────────────────────────────────────────────────────────────

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed creator,
        string questionHash,
        uint256 minimumStake,
        uint256 biddingEndTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 stakeAmount,
        string proposalHash
    );
    event BiddingClosed(uint256 indexed auctionId);
    event ShortlistSet(
        uint256 indexed auctionId,
        address[] finalists
    );
    event AuctionResolved(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 winningScore,
        uint256 indexed nftTokenId
    );
    event StakeWithdrawn(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    event WinningBidsWithdrawn(address indexed to, uint256 amount);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event BackendUpdated(address indexed oldBackend, address indexed newBackend);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InvalidAuction();
    error InvalidState(AuctionState current, AuctionState expected);
    error AuctionNotFound();
    error BiddingNotOpen();
    error StakeTooLow(uint256 minimum, uint256 provided);
    error NoBidsPlaced();
    error NotBackend();
    error WinnerNotShortlisted();
    error AlreadyResolved();
    error InvalidOracleSignature();
    error NothingToWithdraw();
    error WithdrawAlreadyClaimed();
    error ShortlistEmpty();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier auctionExists(uint256 auctionId) {
        if (auctionId == 0 || auctionId > _auctionCounter) revert AuctionNotFound();
        _;
    }

    modifier inState(uint256 auctionId, AuctionState expected) {
        AuctionState current = _auctions[auctionId].state;
        if (current != expected) revert InvalidState(current, expected);
        _;
    }

    modifier onlyBackend() {
        if (msg.sender != backendAddress) revert NotBackend();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _nftContract   Address of the PublishingRightsNFT contract.
     * @param _oracleAddress Initial oracle signer address.
     * @param _backendAddress Initial backend operator address.
     */
    constructor(
        address _nftContract,
        address _oracleAddress,
        address _backendAddress
    ) {
        require(_nftContract != address(0), "Invalid NFT address");
        require(_oracleAddress != address(0), "Invalid oracle address");
        require(_backendAddress != address(0), "Invalid backend address");

        nftContract = PublishingRightsNFT(payable(_nftContract));
        oracleAddress = _oracleAddress;
        backendAddress = _backendAddress;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /**
     * @notice Update the oracle signer address. Only owner.
     */
    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Invalid oracle");
        address oldOracle = oracleAddress;
        oracleAddress = newOracle;
        emit OracleUpdated(oldOracle, newOracle);
    }

    /**
     * @notice Update the backend operator address. Only owner.
     */
    function setBackend(address newBackend) external onlyOwner {
        require(newBackend != address(0), "Invalid backend");
        address oldBackend = backendAddress;
        backendAddress = newBackend;
        emit BackendUpdated(oldBackend, newBackend);
    }

    /**
     * @notice Owner withdraws accumulated winning bid native currency.
     */
    function withdrawWinningBids(address to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        uint256 amount = accumulatedWinningBids;
        require(amount > 0, "Nothing to withdraw");
        accumulatedWinningBids = 0;
        (bool sent, ) = payable(to).call{value: amount}("");
        require(sent, "Transfer failed");
        emit WinningBidsWithdrawn(to, amount);
    }

    // ─── Auction Lifecycle ───────────────────────────────────────────────────

    /**
     * @notice Create a new auction. Only the backend can create auctions.
     * @param questionHash  Hash/identifier of the news item or question.
     * @param minimumStake  Minimum USDC amount a bidder must stake.
     * @param duration      Bidding duration in seconds.
     * @return auctionId    The new auction ID.
     */
    function createAuction(
        string calldata questionHash,
        uint256 minimumStake,
        uint256 duration
    ) external onlyBackend returns (uint256) {
        require(bytes(questionHash).length > 0, "Question hash empty");
        require(duration > 0, "Duration must be > 0");

        unchecked {
            _auctionCounter++;
        }
        uint256 auctionId = _auctionCounter;

        Auction storage a = _auctions[auctionId];
        a.creator = msg.sender;
        a.questionHash = questionHash;
        a.minimumStake = minimumStake;
        a.biddingEndTime = block.timestamp + duration;
        a.state = AuctionState.BIDDING_OPEN;

        emit AuctionCreated(auctionId, msg.sender, questionHash, minimumStake, a.biddingEndTime);

        return auctionId;
    }

    // ─── Bidding ─────────────────────────────────────────────────────────────

    /**
     * @notice Place a bid. Bids are additive — multiple calls accumulate stake.
     *         The proposal hash should reference IPFS or similar storage.
     * @param auctionId    The auction to bid on.
     * @param proposalHash Hash/URI of the proposed question format.
     */
    function placeBid(
        uint256 auctionId,
        string calldata proposalHash
    )
        external
        payable
        nonReentrant
        auctionExists(auctionId)
        inState(auctionId, AuctionState.BIDDING_OPEN)
    {
        Auction storage a = _auctions[auctionId];

        if (block.timestamp > a.biddingEndTime) revert BiddingNotOpen();
        if (msg.value < a.minimumStake) revert StakeTooLow(a.minimumStake, msg.value);
        if (bytes(proposalHash).length == 0) revert InvalidAuction();

        uint256 previousStake = bidderStakes[auctionId][msg.sender];

        // Track this bidder if first bid
        if (previousStake == 0) {
            a.bidders.push(msg.sender);
        }

        bidderStakes[auctionId][msg.sender] = previousStake + msg.value;

        // Store proposal (last submission wins for proposal content)
        bidderProposals[auctionId][msg.sender] = proposalHash;

        emit BidPlaced(auctionId, msg.sender, msg.value, proposalHash);
    }

    /**
     * @notice Close bidding after the deadline. Anyone can call.
     */
    function closeBidding(uint256 auctionId)
        external
        auctionExists(auctionId)
        inState(auctionId, AuctionState.BIDDING_OPEN)
    {
        Auction storage a = _auctions[auctionId];
        if (block.timestamp < a.biddingEndTime) revert BiddingNotOpen();
        if (a.bidders.length == 0) revert NoBidsPlaced();

        a.state = AuctionState.BIDDING_CLOSED;
        emit BiddingClosed(auctionId);
    }

    // ─── Shortlist ───────────────────────────────────────────────────────────

    /**
     * @notice Set the shortlist of finalists (max 3). Only the backend.
     * @dev Called after off-chain AI filtering and deterministic scoring.
     * @param auctionId The auction to set shortlist for.
     * @param finalists Array of ≤3 finalist addresses.
     */
    function setShortlist(
        uint256 auctionId,
        address[] calldata finalists
    )
        external
        onlyBackend
        auctionExists(auctionId)
        inState(auctionId, AuctionState.BIDDING_CLOSED)
    {
        require(finalists.length > 0, "Shortlist empty");
        require(finalists.length <= 3, "Max 3 finalists");

        Auction storage a = _auctions[auctionId];

        // Verify all finalists are bidders
        for (uint256 i = 0; i < finalists.length; i++) {
            require(bidderStakes[auctionId][finalists[i]] > 0, "Finalist not a bidder");
            isShortlisted[auctionId][finalists[i]] = true;
            a.shortlist.push(finalists[i]);
        }

        a.state = AuctionState.SHORTLIST_SET;
        emit ShortlistSet(auctionId, finalists);
    }

    // ─── Resolution ──────────────────────────────────────────────────────────

    /**
     * @notice Resolve the auction with an oracle-signed winner.
     *         Anyone can submit once they have the oracle's signature.
     * @param auctionId      The auction to resolve.
     * @param winner         The winning bidder address.
     * @param winningScore   The winner's aggregated (median) expert score.
     * @param metadataURI    URI for the NFT token metadata.
     * @param oracleSignature ECDSA signature from the oracle over
     *                        (auctionId, winner, winningScore).
     */
    function resolveAuction(
        uint256 auctionId,
        address winner,
        uint256 winningScore,
        string calldata metadataURI,
        bytes calldata oracleSignature
    )
        external
        nonReentrant
        auctionExists(auctionId)
        inState(auctionId, AuctionState.SHORTLIST_SET)
    {
        Auction storage a = _auctions[auctionId];

        // Verify winner is shortlisted
        if (!isShortlisted[auctionId][winner]) revert WinnerNotShortlisted();
        if (a.winnerDeclared) revert AlreadyResolved();

        // Verify oracle signature
        bytes32 messageHash = keccak256(abi.encodePacked(auctionId, winner, winningScore));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(oracleSignature);

        if (signer != oracleAddress) revert InvalidOracleSignature();

        // Record winner
        a.winner = winner;
        a.winningScore = winningScore;
        a.winnerDeclared = true;

        // The winner's stake stays as payment.
        // Move it from staked to accumulatedWinningBids.
        uint256 winnerStake = bidderStakes[auctionId][winner];
        accumulatedWinningBids += winnerStake;
        bidderStakes[auctionId][winner] = 0;

        // Mint publishing rights NFT to winner
        uint256 tokenId = nftContract.mint(winner, auctionId, metadataURI);
        a.nftTokenId = tokenId;

        a.state = AuctionState.COMPLETED;

        emit AuctionResolved(auctionId, winner, winningScore, tokenId);
    }

    // ─── Withdrawals ─────────────────────────────────────────────────────────

    /**
     * @notice Non-winners withdraw their staked USDC after the auction is resolved.
     */
    function withdrawStake(uint256 auctionId)
        external
        nonReentrant
        auctionExists(auctionId)
    {
        Auction storage a = _auctions[auctionId];
        // Must be completed (winner declared and NFT minted)
        if (!a.winnerDeclared) {
            revert InvalidState(a.state, AuctionState.COMPLETED);
        }

        // Winner's stake was already moved to accumulatedWinningBids
        if (msg.sender == a.winner) revert NothingToWithdraw();
        if (stakeWithdrawn[auctionId][msg.sender]) revert WithdrawAlreadyClaimed();

        uint256 amount = bidderStakes[auctionId][msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        bidderStakes[auctionId][msg.sender] = 0;
        stakeWithdrawn[auctionId][msg.sender] = true;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Transfer failed");
        emit StakeWithdrawn(auctionId, msg.sender, amount);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    function getAuction(uint256 auctionId)
        external
        view
        auctionExists(auctionId)
        returns (Auction memory)
    {
        return _auctions[auctionId];
    }

    function getAuctionState(uint256 auctionId)
        external
        view
        auctionExists(auctionId)
        returns (AuctionState)
    {
        return _auctions[auctionId].state;
    }

    function getBidders(uint256 auctionId)
        external
        view
        auctionExists(auctionId)
        returns (address[] memory)
    {
        return _auctions[auctionId].bidders;
    }

    function getShortlist(uint256 auctionId)
        external
        view
        auctionExists(auctionId)
        returns (address[] memory)
    {
        return _auctions[auctionId].shortlist;
    }

    function getBidderStake(uint256 auctionId, address bidder)
        external
        view
        returns (uint256)
    {
        return bidderStakes[auctionId][bidder];
    }

    function getBidderProposal(uint256 auctionId, address bidder)
        external
        view
        returns (string memory)
    {
        return bidderProposals[auctionId][bidder];
    }

    function auctionCount() external view returns (uint256) {
        return _auctionCounter;
    }
}
