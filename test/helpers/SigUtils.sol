// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

/**
 * @title SigUtils
 * @notice ECDSA signing helpers for testing oracle signature verification.
 *
 * Provides utilities to compute the messages that the oracle signs and
 * produce valid ECDSA signatures using a known private key.
 */
contract SigUtils is Test {
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /**
     * @notice Compute the Ethereum signed message hash for AuctionManager's oracle.
     *         Message: keccak256(abi.encodePacked(auctionId, winner, winningScore))
     */
    function getAuctionResolutionHash(
        uint256 auctionId,
        address winner,
        uint256 winningScore
    ) internal pure returns (bytes32) {
        bytes32 messageHash = keccak256(abi.encodePacked(auctionId, winner, winningScore));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }

    /**
     * @notice Compute the Ethereum signed message hash for PredictionMarket's oracle.
     *         Message: keccak256(abi.encodePacked(marketAddress, winningOptionIndex))
     */
    function getMarketResolutionHash(
        address marketAddress,
        uint256 winningOptionIndex
    ) internal pure returns (bytes32) {
        bytes32 messageHash = keccak256(abi.encodePacked(marketAddress, winningOptionIndex));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }

    /**
     * @notice Sign a digest with a known private key and return (v, r, s).
     */
    function signDigest(bytes32 digest, uint256 privateKey)
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(privateKey, digest);
    }

    /**
     * @notice Build a compact signature bytes from (v, r, s).
     */
    function toBytes(uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Sign an auction resolution message and return the compact signature.
     */
    function signAuctionResolution(
        uint256 auctionId,
        address winner,
        uint256 winningScore,
        uint256 oraclePrivateKey
    ) internal pure returns (bytes memory) {
        bytes32 digest = getAuctionResolutionHash(auctionId, winner, winningScore);
        (uint8 v, bytes32 r, bytes32 s) = signDigest(digest, oraclePrivateKey);
        return toBytes(v, r, s);
    }

    /**
     * @notice Sign a market resolution message and return the compact signature.
     */
    function signMarketResolution(
        address marketAddress,
        uint256 winningOptionIndex,
        uint256 oraclePrivateKey
    ) internal pure returns (bytes memory) {
        bytes32 digest = getMarketResolutionHash(marketAddress, winningOptionIndex);
        (uint8 v, bytes32 r, bytes32 s) = signDigest(digest, oraclePrivateKey);
        return toBytes(v, r, s);
    }
}
