// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


/**
 * @title PublishingRightsNFT
 * @notice ERC-721 token representing the exclusive right to publish a prediction
 *         market question and collect trading fees from it.
 *
 * Each token is minted by the AuctionManager when a winner is selected.
 * The token holder can create a prediction market via MarketFactory and
 * claim accumulated trading fees from that market.
 *
 * Tokens are transferable, enabling a secondary market for publishing rights.
 */
contract PublishingRightsNFT is ERC721, Ownable, ReentrancyGuard {

    // ─── Types ───────────────────────────────────────────────────────────────

    struct TokenInfo {
        uint256 auctionId;         // Auction that produced this token
        string metadataURI;         // URI for token metadata (IPFS, etc.)
        address marketAddress;      // Linked PredictionMarket contract
        bool marketActive;          // Whether linked market is unresolved
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    uint256 private _tokenIdCounter;

    mapping(uint256 => TokenInfo) public tokenInfo;
    mapping(address => bool) public isMinter;
    mapping(address => uint256[]) private _ownerTokens;

    // ─── Events ──────────────────────────────────────────────────────────────

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event PublishingRightsMinted(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed auctionId
    );
    event MarketLinked(uint256 indexed tokenId, address indexed market);
    event FeesClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotMinter();
    error NotOwner();
    error TokenDoesNotExist();
    error NoMarketLinked();
    error NoFeesToClaim();
    error MarketAlreadyLinked();
    error CannotUnlinkActiveMarket();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    modifier tokenExists(uint256 tokenId) {
        if (tokenId == 0 || tokenId > _tokenIdCounter) revert TokenDoesNotExist();
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param name_  ERC-721 collection name.
     * @param symbol_ ERC-721 collection symbol.
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) Ownable() {}

    // ─── Receive ────────────────────────────────────────────────────────────

    /// @notice Accept native currency forwarded from PredictionMarket.claimPublisherFees().
    receive() external payable {}

    // ─── Minter Management ───────────────────────────────────────────────────

    /**
     * @notice Add an address to the minter whitelist. Only owner.
     */
    function addMinter(address minter) external onlyOwner {
        require(minter != address(0), "Invalid minter");
        isMinter[minter] = true;
        emit MinterAdded(minter);
    }

    /**
     * @notice Remove an address from the minter whitelist. Only owner.
     */
    function removeMinter(address minter) external onlyOwner {
        isMinter[minter] = false;
        emit MinterRemoved(minter);
    }

    // ─── Minting ─────────────────────────────────────────────────────────────

    /**
     * @notice Mint a new publishing rights token. Only whitelisted minters.
     * @param to          Recipient address (the auction winner).
     * @param auctionId   The auction ID that produced this winner.
     * @param metadataURI URI with details about the winning proposal.
     * @return tokenId    The newly minted token ID.
     */
    function mint(
        address to,
        uint256 auctionId,
        string calldata metadataURI
    ) external onlyMinter returns (uint256) {
        require(to != address(0), "Cannot mint to zero address");
        require(auctionId > 0, "Invalid auction ID");

        unchecked {
            _tokenIdCounter++;
        }
        uint256 tokenId = _tokenIdCounter;

        _safeMint(to, tokenId);

        tokenInfo[tokenId] = TokenInfo({
            auctionId: auctionId,
            metadataURI: metadataURI,
            marketAddress: address(0),
            marketActive: false
        });

        // _ownerTokens is managed by _beforeTokenTransfer hook

        emit PublishingRightsMinted(tokenId, to, auctionId);

        return tokenId;
    }

    // ─── Market Linking ──────────────────────────────────────────────────────

    /**
     * @notice Link a PredictionMarket to this token. Only whitelisted minters.
     * @dev Called by MarketFactory when creating a new prediction market.
     */
    function setMarketAddress(uint256 tokenId, address market)
        external
        onlyMinter
        tokenExists(tokenId)
    {
        TokenInfo storage info = tokenInfo[tokenId];
        if (info.marketAddress == market) revert MarketAlreadyLinked();
        info.marketAddress = market;
        info.marketActive = true;
        emit MarketLinked(tokenId, market);
    }

    /**
     * @notice Mark the linked market as resolved. Only whitelisted minters.
     * @dev Called by PredictionMarket.claimWinnings when all payouts complete.
     */
    function clearMarketActive(uint256 tokenId)
        external
        onlyMinter
        tokenExists(tokenId)
    {
        tokenInfo[tokenId].marketActive = false;
    }

    // ─── Fee Claims ──────────────────────────────────────────────────────────

    /**
     * @notice Claim publisher fees from the linked prediction market.
     *         Only the current token owner can claim.
     * @param tokenId The publishing rights token ID.
     * @return amount The amount of native currency claimed.
     */
    function claimFees(uint256 tokenId)
        external
        nonReentrant
        tokenExists(tokenId)
        onlyTokenOwner(tokenId)
        returns (uint256)
    {
        TokenInfo storage info = tokenInfo[tokenId];
        address market = info.marketAddress;
        if (market == address(0)) revert NoMarketLinked();

        // Call the prediction market's fee claim function.
        // The market will send native currency to this contract.
        (bool success, bytes memory data) = market.call(
            abi.encodeWithSignature("claimPublisherFees()")
        );
        require(success, "Market fee claim failed");

        uint256 amount = abi.decode(data, (uint256));
        if (amount == 0) revert NoFeesToClaim();

        // Forward native currency to the token owner
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Transfer failed");

        emit FeesClaimed(tokenId, msg.sender, amount);

        return amount;
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /**
     * @notice Get the claimable publisher fees for a token (view).
     */
    function getClaimableFees(uint256 tokenId)
        external
        view
        tokenExists(tokenId)
        returns (uint256)
    {
        address market = tokenInfo[tokenId].marketAddress;
        if (market == address(0)) return 0;
        (bool success, bytes memory data) = market.staticcall(
            abi.encodeWithSignature("getClaimablePublisherFees()")
        );
        if (!success) return 0;
        return abi.decode(data, (uint256));
    }

    /**
     * @notice Get the next token ID that will be minted.
     */
    function nextTokenId() external view returns (uint256) {
        return _tokenIdCounter + 1;
    }

    /**
     * @notice Get the total number of tokens minted.
     */
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }

    /**
     * @notice Get all token IDs owned by an address.
     */
    function getTokensByOwner(address owner)
        external
        view
        returns (uint256[] memory)
    {
        return _ownerTokens[owner];
    }

    // ─── Overrides ───────────────────────────────────────────────────────────

    /**
     * @dev Override _beforeTokenTransfer to maintain _ownerTokens tracking.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);

        if (from != address(0)) {
            // Remove token from previous owner's list
            uint256[] storage fromTokens = _ownerTokens[from];
            for (uint256 i = 0; i < fromTokens.length; i++) {
                if (fromTokens[i] == tokenId) {
                    fromTokens[i] = fromTokens[fromTokens.length - 1];
                    fromTokens.pop();
                    break;
                }
            }
        }

        if (to != address(0)) {
            _ownerTokens[to].push(tokenId);
        }
    }
}
