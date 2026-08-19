// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {
    IDocumentRegistry,
    IDocumentRegistryEnumerable,
    Document,
    DocumentReference,
    DOC_TYPE_ORIGINAL,
    DOC_TYPE_AMENDMENT,
    DOC_TYPE_REVISION,
    DOC_TYPE_REPEAL,
    DOC_TYPE_CODIFICATION,
    RELATION_AMENDS,
    RELATION_REVISES,
    RELATION_REPEALS,
    RELATION_CODIFIES,
    RELATION_GOVERNS,
    RELATION_IMPLEMENTS,
    RELATION_REFERENCES,
    RELATION_TEMPLATE
} from "@vattelum/document-registry/DocumentRegistry.sol";

/// @title BVSRegistry — On-Chain Document Registry
/// @notice Append-only registry of ratified documents organized by category with a document
///         layer (categories as folders containing independent documents), external references,
///         and per-document amendment restrictions. Single governance authority (admin EOA).
///         Admin can also reject proposals for the audit trail (event-only, no state change).
///
///         Lock semantics are chosen at deploy time via the immutable `hardLock` flag:
///           * hardLock = false (DAA-style soft-lock): admin can call setAmendmentRestrictions
///             at any time; the AmendmentRestrictionsUpdated event provides the audit trail.
///           * hardLock = true  (registry-style hard-lock): while a lock window is active,
///             setAmendmentRestrictions reverts RestrictionsLocked — admin self-binds and cannot
///             modify or clear the restrictions until the window elapses.
contract BVSRegistry is IDocumentRegistry, IDocumentRegistryEnumerable {
    // ──────────────────────── Structs ──────────────────────────

    struct DocumentInput {
        uint256 categoryId;
        uint256 documentId;
        string contentUri;
        bytes32 contentHash;
        string title;
        string voteId;
        uint8 docType;
    }

    struct AmendmentRestrictions {
        uint256 minTimeBetweenAmendments;
        uint256 lastAmendmentTime;
        uint256[] lockedSections;
    }

    // ──────────────────────── Immutables ──────────────────────

    bool public immutable hardLock;

    // ──────────────────────── State ───────────────────────────

    address public governanceAuthority;
    mapping(uint256 => string) public categoryNames;
    uint256 public categoryCount;
    mapping(uint256 => uint256) private _documentCounts;
    mapping(uint256 => mapping(uint256 => uint256)) private _versionCounts;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => Document))) private _documents;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => DocumentReference[]))) private _references;
    mapping(uint256 => mapping(uint256 => AmendmentRestrictions)) private _amendmentRestrictions;

    // ──────────────────────── Events ──────────────────────────

    event CategoryAdded(uint256 indexed categoryId, string name);
    event GovernanceAuthorityTransferred(address indexed previous, address indexed current);
    event ProposalRejected(
        uint256 indexed snapshotProposalId,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        string reason
    );
    event AmendmentRestrictionsUpdated(uint256 indexed categoryId, uint256 indexed documentId);

    // ──────────────────────── Errors ──────────────────────────

    error NotGovernance();
    error CategoryDoesNotExist(uint256 categoryId);
    error DocumentDoesNotExist(uint256 categoryId, uint256 documentId);
    error VersionDoesNotExist(uint256 categoryId, uint256 documentId, uint256 version);
    error InvalidAuthority();
    error AmendmentTooSoon(uint256 categoryId, uint256 documentId, uint256 earliestAllowed);
    error SectionLocked(uint256 categoryId, uint256 documentId, uint256 lockedSection);
    error IndexOutOfRange(uint256 index, uint256 count);
    error RestrictionsLocked(uint256 categoryId, uint256 documentId, uint256 earliestAllowed);

    // ──────────────────────── Modifiers ──────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governanceAuthority) {
            revert NotGovernance();
        }
        _;
    }

    // ──────────────────────── Constructor ─────────────────────

    constructor(address _governanceAuthority, bool _hardLock) {
        if (_governanceAuthority == address(0)) {
            revert InvalidAuthority();
        }
        governanceAuthority = _governanceAuthority;
        hardLock = _hardLock;
        emit GovernanceAuthorityTransferred(address(0), _governanceAuthority);
    }

    // ──────────────────────── Public / External ──────────────

    /// @notice Create a new document category.
    function addCategory(string calldata name) external onlyGovernance returns (uint256) {
        uint256 categoryId = categoryCount++;
        categoryNames[categoryId] = name;

        emit CategoryAdded(categoryId, name);
        return categoryId;
    }

    /// @notice Record a ratified document on-chain. Append-only.
    /// @param input Document metadata. documentId = 0 creates a new document, > 0 amends existing.
    /// @param refs Array of external references (can be empty).
    /// @return documentId The document ID (new or existing).
    /// @return version The auto-incremented version number assigned.
    function addDocument(DocumentInput calldata input, DocumentReference[] calldata refs)
        external
        onlyGovernance
        returns (uint256 documentId, uint256 version)
    {
        if (input.categoryId >= categoryCount) {
            revert CategoryDoesNotExist(input.categoryId);
        }

        if (input.documentId == 0) {
            documentId = ++_documentCounts[input.categoryId];
        } else {
            if (input.documentId > _documentCounts[input.categoryId]) {
                revert DocumentDoesNotExist(input.categoryId, input.documentId);
            }
            documentId = input.documentId;
        }

        AmendmentRestrictions storage restrictions = _amendmentRestrictions[input.categoryId][documentId];
        if (
            restrictions.minTimeBetweenAmendments > 0 &&
            restrictions.lastAmendmentTime > 0 &&
            block.timestamp < restrictions.lastAmendmentTime + restrictions.minTimeBetweenAmendments
        ) {
            revert AmendmentTooSoon(
                input.categoryId,
                documentId,
                restrictions.lastAmendmentTime + restrictions.minTimeBetweenAmendments
            );
        }

        // Amendment-family docTypes (Amendment, Revision, Repeal) may not target a locked
        // section. refs[0] carries the target per Referencing Standard §3.1; when refs[0]
        // points at a local document, its lockedSections govern. Multi-target targetSection
        // strings are split on commas; subsection identifiers (e.g. "3.1") resolve to their
        // root (3) for lock purposes.
        if (
            input.docType == DOC_TYPE_AMENDMENT ||
            input.docType == DOC_TYPE_REVISION ||
            input.docType == DOC_TYPE_REPEAL
        ) {
            if (refs.length > 0 && refs[0].registryAddress == address(this)) {
                uint256 targetCat = refs[0].categoryId;
                uint256 targetDoc = refs[0].documentId;
                if (
                    targetCat < categoryCount &&
                    targetDoc > 0 &&
                    targetDoc <= _documentCounts[targetCat]
                ) {
                    _checkLockedSections(
                        refs[0].targetSection,
                        _amendmentRestrictions[targetCat][targetDoc].lockedSections,
                        targetCat,
                        targetDoc
                    );
                }
            }
        }

        version = ++_versionCounts[input.categoryId][documentId];

        _documents[input.categoryId][documentId][version] = Document({
            contentUri: input.contentUri,
            contentHash: input.contentHash,
            title: input.title,
            version: version,
            timestamp: block.timestamp,
            voteId: input.voteId,
            docType: input.docType
        });

        for (uint256 i = 0; i < refs.length; i++) {
            _references[input.categoryId][documentId][version].push(refs[i]);
        }

        if (restrictions.minTimeBetweenAmendments > 0) {
            restrictions.lastAmendmentTime = block.timestamp;
        }

        emit DocumentAdded(input.categoryId, documentId, version, input.contentUri, input.contentHash, input.docType);
    }

    /// @notice Record an admin rejection of a Snapshot X proposal for the audit trail.
    /// @dev Event-only, no state change. Admin can call at any time, regardless of voting state.
    function rejectProposal(
        uint256 snapshotProposalId,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        string calldata reason
    ) external onlyGovernance {
        emit ProposalRejected(snapshotProposalId, votesFor, votesAgainst, votesAbstain, reason);
    }

    /// @notice Configure amendment restrictions for a document.
    /// @dev When `hardLock` is true and the document is currently inside an active lock
    ///      window, this call reverts `RestrictionsLocked` — admin cannot modify or clear
    ///      the restrictions until `lastAmendmentTime + minTimeBetweenAmendments` elapses.
    ///      When `hardLock` is false, admin may always overwrite (DAA soft-lock semantics);
    ///      the audit trail is the AmendmentRestrictionsUpdated event.
    function setAmendmentRestrictions(
        uint256 categoryId,
        uint256 documentId,
        uint256 minTimeBetweenAmendments,
        uint256[] calldata lockedSections
    ) external onlyGovernance {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        AmendmentRestrictions storage r = _amendmentRestrictions[categoryId][documentId];

        if (hardLock) {
            if (
                r.minTimeBetweenAmendments > 0 &&
                r.lastAmendmentTime > 0 &&
                block.timestamp < r.lastAmendmentTime + r.minTimeBetweenAmendments
            ) {
                revert RestrictionsLocked(
                    categoryId,
                    documentId,
                    r.lastAmendmentTime + r.minTimeBetweenAmendments
                );
            }
        }

        r.minTimeBetweenAmendments = minTimeBetweenAmendments;
        r.lockedSections = lockedSections;

        emit AmendmentRestrictionsUpdated(categoryId, documentId);
    }

    // ──────────────────────── Read Functions ──────────────────

    /// @notice Retrieve a specific document version.
    function getDocument(uint256 categoryId, uint256 documentId, uint256 version)
        external
        view
        override
        returns (Document memory)
    {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        if (version == 0 || version > _versionCounts[categoryId][documentId]) {
            revert VersionDoesNotExist(categoryId, documentId, version);
        }
        return _documents[categoryId][documentId][version];
    }

    /// @notice Retrieve the most recent version of a document.
    function getLatest(uint256 categoryId, uint256 documentId) external view returns (Document memory) {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        uint256 latest = _versionCounts[categoryId][documentId];
        if (latest == 0) {
            revert VersionDoesNotExist(categoryId, documentId, 0);
        }
        return _documents[categoryId][documentId][latest];
    }

    /// @notice Retrieve all versions of a document.
    function getHistory(uint256 categoryId, uint256 documentId) external view override returns (Document[] memory) {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        uint256 count = _versionCounts[categoryId][documentId];
        Document[] memory docs = new Document[](count);
        for (uint256 i = 0; i < count; i++) {
            docs[i] = _documents[categoryId][documentId][i + 1];
        }
        return docs;
    }

    /// @notice Retrieve external references for a document version.
    function getReferences(uint256 categoryId, uint256 documentId, uint256 version)
        external
        view
        override
        returns (DocumentReference[] memory)
    {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        if (version == 0 || version > _versionCounts[categoryId][documentId]) {
            revert VersionDoesNotExist(categoryId, documentId, version);
        }
        return _references[categoryId][documentId][version];
    }

    /// @notice Retrieve the version count for a document.
    function getVersionCount(uint256 categoryId, uint256 documentId) external view returns (uint256) {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        return _versionCounts[categoryId][documentId];
    }

    /// @notice Retrieve the document count for a category.
    function getDocumentCount(uint256 categoryId) external view override returns (uint256) {
        _requireCategory(categoryId);
        return _documentCounts[categoryId];
    }

    /// @notice Number of categories, for position-based enumeration.
    function getCategoryCount() external view override returns (uint256) {
        return categoryCount;
    }

    /// @notice Category id at a 0-based position. Categories are numbered from 0, so position and
    ///         id coincide here; consumers read through this accessor rather than assuming that.
    function getCategoryIdAt(uint256 index) external view override returns (uint256) {
        if (index >= categoryCount) {
            revert IndexOutOfRange(index, categoryCount);
        }
        return index;
    }

    /// @notice Document id at a 0-based position within a category. Documents are numbered from 1.
    function getDocumentIdAt(uint256 categoryId, uint256 index) external view override returns (uint256) {
        _requireCategory(categoryId);
        uint256 count = _documentCounts[categoryId];
        if (index >= count) {
            revert IndexOutOfRange(index, count);
        }
        return index + 1;
    }

    /// @notice Retrieve amendment restrictions for a document.
    function getAmendmentRestrictions(uint256 categoryId, uint256 documentId)
        external
        view
        returns (uint256 minTimeBetweenAmendments, uint256 lastAmendmentTime, uint256[] memory lockedSections)
    {
        _requireCategory(categoryId);
        _requireDocument(categoryId, documentId);
        AmendmentRestrictions storage r = _amendmentRestrictions[categoryId][documentId];
        return (r.minTimeBetweenAmendments, r.lastAmendmentTime, r.lockedSections);
    }

    // ──────────────────────── Governance ──────────────────────

    /// @notice Transfer the governance authority address.
    /// @param newAuthority The new authority (cannot be address(0)).
    function setGovernanceAuthority(address newAuthority) external onlyGovernance {
        if (newAuthority == address(0)) {
            revert InvalidAuthority();
        }
        address previous = governanceAuthority;
        governanceAuthority = newAuthority;
        emit GovernanceAuthorityTransferred(previous, newAuthority);
    }

    // ──────────────────────── Internal ────────────────────────

    function _requireCategory(uint256 categoryId) internal view {
        if (categoryId >= categoryCount) {
            revert CategoryDoesNotExist(categoryId);
        }
    }

    function _requireDocument(uint256 categoryId, uint256 documentId) internal view {
        if (documentId == 0 || documentId > _documentCounts[categoryId]) {
            revert DocumentDoesNotExist(categoryId, documentId);
        }
    }

    /// @dev Parse a targetSection string (e.g. "3", "3.1", "3,5,7.2") and revert if any
    ///      root section number appears in the provided lockedSections. Digits before a
    ///      '.' or ',' form the root; non-digit characters terminate the current number.
    function _checkLockedSections(
        string memory targetSection,
        uint256[] storage lockedSections,
        uint256 targetCategoryId,
        uint256 targetDocumentId
    ) internal view {
        if (lockedSections.length == 0) return;
        bytes memory bs = bytes(targetSection);
        if (bs.length == 0) return;

        uint256 current = 0;
        bool reading = true;
        bool hasDigit = false;

        for (uint256 i = 0; i < bs.length; i++) {
            bytes1 c = bs[i];
            if (c == 0x2C /* ',' */) {
                if (hasDigit) {
                    _revertIfLocked(current, lockedSections, targetCategoryId, targetDocumentId);
                }
                current = 0;
                reading = true;
                hasDigit = false;
            } else if (c == 0x2E /* '.' */) {
                reading = false;
            } else if (reading && c >= 0x30 && c <= 0x39) {
                current = current * 10 + (uint8(c) - 0x30);
                hasDigit = true;
            }
        }
        if (hasDigit) {
            _revertIfLocked(current, lockedSections, targetCategoryId, targetDocumentId);
        }
    }

    function _revertIfLocked(
        uint256 sectionNumber,
        uint256[] storage lockedSections,
        uint256 targetCategoryId,
        uint256 targetDocumentId
    ) internal view {
        for (uint256 i = 0; i < lockedSections.length; i++) {
            if (lockedSections[i] == sectionNumber) {
                revert SectionLocked(targetCategoryId, targetDocumentId, sectionNumber);
            }
        }
    }
}
