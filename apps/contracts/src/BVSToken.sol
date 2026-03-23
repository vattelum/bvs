// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";

/// @title BVSToken — Soulbound Membership Token
/// @notice ERC-721 + ERC-5192 non-transferable membership token with identity credentials
///         and an optional pluggable verifier gate. Admin-only minting in BVS mode.
contract BVSToken is ERC721, Ownable, IERC5192 {
    // ──────────────────────── Constants ────────────────────────

    bytes4 private constant _IERC5192_INTERFACE_ID = 0xb45a3c0e;

    // ──────────────────────── Immutables ─────────────────────

    bool public immutable singleTokenPerAddress;
    bool public immutable adminCanBurn;

    // ──────────────────────── State ───────────────────────────

    uint256 private _nextTokenId;
    IVerifier public verifier;
    mapping(uint256 => bytes) private _credentials;

    // ──────────────────────── Events ──────────────────────────

    event Minted(address indexed to, uint256 indexed tokenId);
    event Burned(address indexed from, uint256 indexed tokenId);
    event VerifierSet(address indexed verifier);

    // ──────────────────────── Errors ──────────────────────────

    error Soulbound();
    error NotTokenHolder();
    error NotAuthorizedToBurn();
    error AlreadyMember(address account);
    error VerifierRejected(address account);

    // ──────────────────────── Constructor ─────────────────────

    constructor(address initialOwner, bool _singleTokenPerAddress, bool _adminCanBurn)
        ERC721("BVS Membership", "BVS")
        Ownable(initialOwner)
    {
        singleTokenPerAddress = _singleTokenPerAddress;
        adminCanBurn = _adminCanBurn;
    }

    // ──────────────────────── Public / External ──────────────

    /// @notice Mint a soulbound membership token to the given address.
    /// @param to Recipient wallet address.
    /// @param credential Arbitrary identity credential bytes (can be empty).
    function mint(address to, bytes calldata credential) external onlyOwner {
        if (singleTokenPerAddress && balanceOf(to) > 0) {
            revert AlreadyMember(to);
        }
        if (address(verifier) != address(0) && !verifier.isVerified(to)) {
            revert VerifierRejected(to);
        }

        uint256 tokenId = _nextTokenId++;
        _credentials[tokenId] = credential;
        _safeMint(to, tokenId);

        emit Locked(tokenId);
        emit Minted(to, tokenId);
    }

    /// @notice Burn a membership token. Holder can always burn their own.
    ///         Admin can burn any token if adminCanBurn is enabled.
    /// @param tokenId The token to burn.
    function burn(uint256 tokenId) external {
        address holder = ownerOf(tokenId);
        bool isHolder = holder == msg.sender;
        bool isAdmin = adminCanBurn && msg.sender == owner();
        if (!isHolder && !isAdmin) {
            revert NotAuthorizedToBurn();
        }
        _burn(tokenId);
        delete _credentials[tokenId];

        emit Burned(holder, tokenId);
    }

    /// @notice Returns the identity credential stored with a token.
    /// @param tokenId The token to query.
    /// @return The credential bytes.
    function getCredential(uint256 tokenId) external view returns (bytes memory) {
        _requireOwned(tokenId);
        return _credentials[tokenId];
    }

    /// @notice ERC-5192: Returns the lock status of a token. Always true (soulbound).
    /// @param tokenId The token to query.
    /// @return True (always locked).
    function locked(uint256 tokenId) external view override returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// @notice Set or remove the optional minting verifier contract.
    /// @param verifierAddress The verifier contract address, or address(0) to remove.
    function setVerifier(address verifierAddress) external onlyOwner {
        verifier = IVerifier(verifierAddress);
        emit VerifierSet(verifierAddress);
    }

    /// @notice ERC-165 interface support.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721)
        returns (bool)
    {
        return interfaceId == _IERC5192_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    // ──────────────────────── Internal ────────────────────────

    /// @dev Override _update to block all transfers. Only mint (from=0) and burn (to=0) allowed.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert Soulbound();
        }
        return super._update(to, tokenId, auth);
    }
}
