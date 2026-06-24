// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PublishingRightsNFT.sol";
import "./PredictionMarket.sol";

/**
 * @title MarketFactory
 * @notice Deploys PredictionMarket instances and links them to PublishingRightsNFT tokens.
 *
 * Only the holder of a PublishingRightsNFT can create a prediction market
 * for that token. One market per token at a time.
 */
contract MarketFactory is Ownable {
    // ─── Storage ─────────────────────────────────────────────────────────────

    PublishingRightsNFT public immutable nftContract;
    address public oracleAddress;
    address public platformAddress;
    uint256 public platformFeeBps;

    address[] public deployedMarkets;
    mapping(uint256 => address) public tokenToMarket;
    mapping(address => uint256) public marketToToken;

    // ─── Events ──────────────────────────────────────────────────────────────

    event MarketDeployed(
        address indexed marketAddress,
        uint256 indexed tokenId,
        address indexed publisher
    );
    event OracleUpdated(address indexed newOracle);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event PlatformUpdated(address indexed newPlatform);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotNFTOwner();
    error MarketAlreadyExists();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _nftContract     PublishingRightsNFT contract.
     * @param _oracleAddress   Oracle signer for ECDSA resolution.
     * @param _platformAddress Platform fee recipient.
     * @param _platformFeeBps  Platform fee share (basis points).
     */
    constructor(
        address _nftContract,
        address _oracleAddress,
        address _platformAddress,
        uint256 _platformFeeBps
    ) {
        require(_nftContract != address(0), "Invalid NFT");
        require(_oracleAddress != address(0), "Invalid oracle");
        require(_platformAddress != address(0), "Invalid platform");
        require(_platformFeeBps <= 10000, "BPS <= 10000");

        nftContract = PublishingRightsNFT(payable(_nftContract));
        oracleAddress = _oracleAddress;
        platformAddress = _platformAddress;
        platformFeeBps = _platformFeeBps;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Invalid oracle");
        oracleAddress = newOracle;
        emit OracleUpdated(newOracle);
    }

    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10000, "BPS <= 10000");
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    function setPlatform(address newPlatform) external onlyOwner {
        require(newPlatform != address(0), "Invalid platform");
        platformAddress = newPlatform;
        emit PlatformUpdated(newPlatform);
    }

    // ─── Market Creation ─────────────────────────────────────────────────────

    /**
     * @notice Create a new prediction market. Caller must own the NFT.
     * @param _tokenId         Publishing rights token ID.
     * @param _question        The prediction market question.
     * @param _options         Array of outcome options.
     * @param _bettingDuration Duration of the betting window in seconds.
     * @param _feeBps          Publisher fee in basis points (e.g., 500 = 5%).
     * @return marketAddress   Address of the newly deployed PredictionMarket.
     */
    function createMarket(
        uint256 _tokenId,
        string calldata _question,
        string[] calldata _options,
        uint256 _bettingDuration,
        uint256 _feeBps
    ) external returns (address) {
        // Verify caller owns the NFT
        if (nftContract.ownerOf(_tokenId) != msg.sender) revert NotNFTOwner();

        // One market per token at a time
        if (tokenToMarket[_tokenId] != address(0)) revert MarketAlreadyExists();

        // Deploy new PredictionMarket
        PredictionMarket market = new PredictionMarket(
            address(nftContract),
            _tokenId,
            _question,
            _options,
            _bettingDuration,
            _feeBps,
            oracleAddress,
            platformAddress,
            platformFeeBps
        );

        address marketAddress = address(market);

        // Link the market to the NFT
        nftContract.setMarketAddress(_tokenId, marketAddress);

        // Store registries
        deployedMarkets.push(marketAddress);
        tokenToMarket[_tokenId] = marketAddress;
        marketToToken[marketAddress] = _tokenId;

        emit MarketDeployed(marketAddress, _tokenId, msg.sender);

        return marketAddress;
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    function getDeployedMarkets() external view returns (address[] memory) {
        return deployedMarkets;
    }

    function getMarketCount() external view returns (uint256) {
        return deployedMarkets.length;
    }
}
