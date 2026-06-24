// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title PredictionMarket
 * @notice Phase 2: Per-market prediction betting contract.
 *
 * Each market instance represents a single prediction market with a set of
 * outcome options. Users bet native currency on their chosen option. A fee
 * is deducted from each bet and added to the publisher's fee pool (claimed
 * by the NFT holder via PublishingRightsNFT). After the betting window
 * closes, an off-chain oracle resolves the outcome via an ECDSA-signed message.
 *
 * Winning bettors receive their stake plus a proportional share of losing bets.
 *
 * Lifecycle:
 *   BETTING_OPEN → BETTING_CLOSED → RESOLVED → (COMPLETED)
 */
contract PredictionMarket is ReentrancyGuard {
    using ECDSA for bytes32;

    // ─── Types ───────────────────────────────────────────────────────────────

    enum MarketState {
        INACTIVE,
        BETTING_OPEN,
        BETTING_CLOSED,
        RESOLVED
    }

    // ─── Immutable Storage ───────────────────────────────────────────────────

    address public immutable nftContract;
    uint256 public immutable tokenId;
    address public immutable oracleAddress;
    address public immutable platformAddress;
    uint256 public immutable platformFeeBps;

    // ─── Market Data ─────────────────────────────────────────────────────────

    struct Market {
        string question;
        string[] options;
        uint256 bettingEndTime;
        uint256 feeBps;
        uint256 winningOptionIndex;
        MarketState state;
    }

    Market private _market;

    // ─── Financial Tracking ──────────────────────────────────────────────────

    uint256 public totalBetPool;             // Total native currency bet (after fee deduction)
    uint256 public totalFeePool;             // Accumulated publisher fees
    uint256 public totalWinningBets;         // Total bets on winning option

    mapping(uint256 => uint256) public optionPoolAmounts;   // optionIndex → total bets
    mapping(address => mapping(uint256 => uint256)) public userBetAmounts; // user → option → amount
    mapping(address => bool) public hasClaimed;

    bool public publisherFeesClaimed;

    // ─── Events ──────────────────────────────────────────────────────────────

    event MarketCreated(
        string question,
        uint256 optionsCount,
        uint256 feeBps,
        uint256 bettingEndTime
    );
    event BetPlaced(
        address indexed bettor,
        uint256 indexed optionIndex,
        uint256 betAmount,
        uint256 feeAmount
    );
    event BettingClosed();
    event MarketResolved(uint256 indexed winningOptionIndex);
    event WinningsClaimed(address indexed claimant, uint256 amount);
    event PublisherFeesClaimed(address indexed publisher, uint256 amount, uint256 platformFee);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotNFTOwner();
    error InvalidOptionIndex();
    error InvalidBetAmount();
    error InvalidState(MarketState current, MarketState expected);
    error BiddingClosed_();
    error BettingStillActive();
    error AlreadyClaimed();
    error NothingToClaim();
    error InvalidOracleSignature();
    error FeesAlreadyClaimed();
    error UsePlaceBet();
    error NoWinningBets();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier inState(MarketState expected) {
        MarketState current = _market.state;
        if (current != expected) revert InvalidState(current, expected);
        _;
    }

    modifier onlyNFTHolder() {
        // Check that the caller owns the linked publishing rights NFT.
        // We use a low-level call to avoid needing an explicit interface import.
        (bool success, bytes memory data) = nftContract.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );
        require(success, "NFT owner check failed");
        address owner = abi.decode(data, (address));
        if (owner != msg.sender) revert NotNFTOwner();
        _;
    }

    modifier onlyNFTContract() {
        if (msg.sender != nftContract) revert NotNFTOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @notice Deployed by MarketFactory. Initial market state is set here.
     * @param _nftContract     PublishingRightsNFT contract address.
     * @param _tokenId         The publishing rights token ID.
     * @param _question        The prediction market question.
     * @param _options         Array of outcome options.
     * @param _bettingDuration Duration of the betting window in seconds.
     * @param _feeBps          Publisher fee in basis points (e.g., 500 = 5%).
     * @param _oracleAddress   Oracle signer for ECDSA resolution.
     * @param _platformAddress Platform fee recipient.
     * @param _platformFeeBps  Platform fee share from publisher fees (basis points).
     */
    constructor(
        address _nftContract,
        uint256 _tokenId,
        string memory _question,
        string[] memory _options,
        uint256 _bettingDuration,
        uint256 _feeBps,
        address _oracleAddress,
        address _platformAddress,
        uint256 _platformFeeBps
    ) {
        require(_nftContract != address(0), "Invalid NFT");
        require(_tokenId > 0, "Invalid token ID");
        require(bytes(_question).length > 0, "Question empty");
        require(_options.length >= 2, "Need >= 2 options");
        require(_bettingDuration > 0, "Duration > 0");
        require(_feeBps <= 10000, "Fee BPS <= 10000");
        require(_oracleAddress != address(0), "Invalid oracle");
        require(_platformAddress != address(0), "Invalid platform");
        require(_platformFeeBps <= 10000, "Platform BPS <= 10000");

        nftContract = _nftContract;
        tokenId = _tokenId;
        oracleAddress = _oracleAddress;
        platformAddress = _platformAddress;
        platformFeeBps = _platformFeeBps;

        _market.question = _question;
        for (uint256 i = 0; i < _options.length; i++) {
            _market.options.push(_options[i]);
        }
        _market.bettingEndTime = block.timestamp + _bettingDuration;
        _market.feeBps = _feeBps;
        _market.state = MarketState.BETTING_OPEN;

        emit MarketCreated(_question, _options.length, _feeBps, _market.bettingEndTime);
    }

    // ─── Receive / Fallback ──────────────────────────────────────────────────

    /// @notice Reject plain ETH transfers. Users must call placeBet() instead.
    receive() external payable {
        revert UsePlaceBet();
    }

    /// @notice Reject calls with unmatched function selectors.
    fallback() external payable {
        revert UsePlaceBet();
    }

    // ─── Betting ─────────────────────────────────────────────────────────────

    /**
     * @notice Place a bet on an outcome option.
     *         A fee is deducted (feeBps%) and added to the publisher's fee pool.
     * @param optionIndex Index of the outcome option to bet on (0-based).
     */
    function placeBet(uint256 optionIndex)
        external
        payable
        nonReentrant
        inState(MarketState.BETTING_OPEN)
    {
        if (block.timestamp > _market.bettingEndTime) revert BiddingClosed_();
        if (optionIndex >= _market.options.length) revert InvalidOptionIndex();
        if (msg.value == 0) revert InvalidBetAmount();

        // Calculate fee and bet portions
        uint256 feeAmount = (msg.value * _market.feeBps) / 10000;
        uint256 betAmount = msg.value - feeAmount;

        // Track bets
        optionPoolAmounts[optionIndex] += betAmount;
        userBetAmounts[msg.sender][optionIndex] += betAmount;

        // Accumulate pools
        totalBetPool += betAmount;
        totalFeePool += feeAmount;

        emit BetPlaced(msg.sender, optionIndex, betAmount, feeAmount);
    }

    /**
     * @notice Close the betting window. Anyone can call after deadline.
     */
    function closeBetting()
        external
        inState(MarketState.BETTING_OPEN)
    {
        if (block.timestamp < _market.bettingEndTime) revert BettingStillActive();
        _market.state = MarketState.BETTING_CLOSED;
        emit BettingClosed();
    }

    // ─── Resolution ──────────────────────────────────────────────────────────

    /**
     * @notice Resolve the market with an oracle-signed outcome.
     *         Anyone can submit once they have the oracle's signature.
     * @param winningOptionIndex Index of the winning outcome option.
     * @param oracleSignature    ECDSA signature from the oracle over
     *                           (contract address, winningOptionIndex).
     */
    function resolveMarket(
        uint256 winningOptionIndex,
        bytes calldata oracleSignature
    )
        external
        nonReentrant
        inState(MarketState.BETTING_CLOSED)
    {
        if (winningOptionIndex >= _market.options.length) revert InvalidOptionIndex();

        // Verify oracle signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(address(this), winningOptionIndex)
        );
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(oracleSignature);

        if (signer != oracleAddress) revert InvalidOracleSignature();

        // Record outcome
        _market.winningOptionIndex = winningOptionIndex;
        totalWinningBets = optionPoolAmounts[winningOptionIndex];
        _market.state = MarketState.RESOLVED;

        emit MarketResolved(winningOptionIndex);
    }

    // ─── Claiming ────────────────────────────────────────────────────────────

    /**
     * @notice Winning bettors claim their proportional share of the bet pool.
     * @return amount USDC claimed.
     */
    function claimWinnings()
        external
        nonReentrant
        inState(MarketState.RESOLVED)
        returns (uint256)
    {
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        uint256 winningIdx = _market.winningOptionIndex;
        uint256 userBetOnWinner = userBetAmounts[msg.sender][winningIdx];

        if (userBetOnWinner == 0) revert NothingToClaim();

        hasClaimed[msg.sender] = true;

        // Parimutuel payout:
        // claimable = userBet + (userBet * losingBets) / totalWinningBets
        uint256 claimable = userBetOnWinner;

        if (totalBetPool > totalWinningBets && totalWinningBets > 0) {
            uint256 totalLosingBets = totalBetPool - totalWinningBets;
            claimable += (userBetOnWinner * totalLosingBets) / totalWinningBets;
        }

        // Reset user bet to prevent double-claim
        userBetAmounts[msg.sender][winningIdx] = 0;

        (bool sent, ) = payable(msg.sender).call{value: claimable}("");
        require(sent, "Transfer failed");

        emit WinningsClaimed(msg.sender, claimable);

        return claimable;
    }

    /**
     * @notice Claim publisher fees. Only callable by the PublishingRightsNFT contract,
     *         which proxies the USDC to the current NFT holder.
     * @return amount USDC sent to the NFT contract.
     */
    function claimPublisherFees()
        external
        nonReentrant
        onlyNFTContract
        returns (uint256)
    {
        if (publisherFeesClaimed) revert FeesAlreadyClaimed();
        publisherFeesClaimed = true;

        uint256 feePool = totalFeePool;
        if (feePool == 0) revert NothingToClaim();

        totalFeePool = 0;

        // Platform cut from the fee pool
        uint256 platformCut = (feePool * platformFeeBps) / 10000;
        uint256 publisherCut = feePool - platformCut;

        if (platformCut > 0) {
            (bool sentPlatform, ) = payable(platformAddress).call{value: platformCut}("");
            require(sentPlatform, "Platform transfer failed");
        }

        // Send publisher portion to the NFT contract (which will forward to holder)
        (bool sentPublisher, ) = payable(msg.sender).call{value: publisherCut}("");
        require(sentPublisher, "Publisher transfer failed");

        emit PublisherFeesClaimed(msg.sender, publisherCut, platformCut);

        return publisherCut;
    }

    /**
     * @notice Recover the bet pool if the winning option received zero bets.
     *         Only callable when the market is RESOLVED and nobody can claim
     *         winnings. Funds are sent to the platform address.
     */
    function recoverUnclaimedFunds()
        external
        nonReentrant
        inState(MarketState.RESOLVED)
    {
        if (totalWinningBets > 0) revert NoWinningBets();
        uint256 pool = totalBetPool;
        if (pool == 0) revert NothingToClaim();
        totalBetPool = 0;
        (bool sent, ) = payable(platformAddress).call{value: pool}("");
        require(sent, "Transfer failed");
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    function getMarketDetails()
        external
        view
        returns (
            string memory question,
            string[] memory options,
            uint256 bettingEndTime,
            uint256 feeBps,
            uint256 winningOptionIndex,
            MarketState state
        )
    {
        return (
            _market.question,
            _market.options,
            _market.bettingEndTime,
            _market.feeBps,
            _market.winningOptionIndex,
            _market.state
        );
    }

    function getOptionPoolAmounts() external view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](_market.options.length);
        for (uint256 i = 0; i < _market.options.length; i++) {
            amounts[i] = optionPoolAmounts[i];
        }
        return amounts;
    }

    function getOptionCount() external view returns (uint256) {
        return _market.options.length;
    }

    function getMarketState() external view returns (MarketState) {
        return _market.state;
    }

    /**
     * @notice Calculate claimable winnings for a user (view).
     */
    function getClaimableWinnings(address user) external view returns (uint256) {
        if (_market.state != MarketState.RESOLVED) return 0;
        if (hasClaimed[user]) return 0;

        uint256 winningIdx = _market.winningOptionIndex;
        uint256 userBetOnWinner = userBetAmounts[user][winningIdx];
        if (userBetOnWinner == 0) return 0;

        uint256 claimable = userBetOnWinner;
        if (totalBetPool > totalWinningBets && totalWinningBets > 0) {
            uint256 totalLosingBets = totalBetPool - totalWinningBets;
            claimable += (userBetOnWinner * totalLosingBets) / totalWinningBets;
        }

        return claimable;
    }

    /**
     * @notice Get claimable publisher fees (view).
     */
    function getClaimablePublisherFees() external view returns (uint256) {
        if (!publisherFeesClaimed) {
            return totalFeePool;
        }
        return 0;
    }
}
