// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {BVSRegistry} from "../src/BVSRegistry.sol";
import {Document, DocumentReference} from "@vattelum/document-registry/DocumentRegistry.sol";

contract BVSRegistryTest is Test {
    BVSRegistry registry;

    address admin = makeAddr("admin");
    address newAdmin = makeAddr("newAdmin");
    address stranger = makeAddr("stranger");

    bytes32 constant HASH_A = keccak256("document-a");
    bytes32 constant HASH_B = keccak256("document-b");
    bytes32 constant HASH_C = keccak256("document-c");

    event CategoryAdded(uint256 indexed categoryId, string name);
    event DocumentAdded(
        uint256 indexed categoryId,
        uint256 indexed documentId,
        uint256 indexed version,
        string contentUri,
        bytes32 contentHash,
        uint8 docType
    );
    event GovernanceAuthorityTransferred(address indexed previous, address indexed current);
    event ProposalRejected(
        uint256 indexed snapshotProposalId,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        string reason
    );
    event AmendmentRestrictionsUpdated(uint256 indexed categoryId, uint256 indexed documentId);

    function setUp() public {
        // Default tests run with soft-lock (DAA semantics). Hard-lock specifics are in
        // BVSRegistryHardLockTest below.
        registry = new BVSRegistry(admin, false);
    }

    function _createCategory(string memory name) internal returns (uint256) {
        vm.prank(admin);
        return registry.addCategory(name);
    }

    function _addNewDocument(
        uint256 categoryId,
        string memory contentUri,
        bytes32 contentHash,
        string memory title,
        string memory voteId_,
        uint8 docType
    ) internal returns (uint256, uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: categoryId,
            documentId: 0,
            contentUri: contentUri,
            contentHash: contentHash,
            title: title,
            voteId: voteId_,
            docType: docType
        });
        DocumentReference[] memory refs = new DocumentReference[](0);
        vm.prank(admin);
        return registry.addDocument(input, refs);
    }

    function _addNewVersion(
        uint256 categoryId,
        uint256 documentId,
        string memory contentUri,
        bytes32 contentHash,
        string memory title,
        string memory voteId_,
        uint8 docType
    ) internal returns (uint256, uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: categoryId,
            documentId: documentId,
            contentUri: contentUri,
            contentHash: contentHash,
            title: title,
            voteId: voteId_,
            docType: docType
        });
        DocumentReference[] memory refs = new DocumentReference[](0);
        vm.prank(admin);
        return registry.addDocument(input, refs);
    }

    function _amendDocument(
        uint256 categoryId,
        uint256 documentId,
        string memory contentUri,
        bytes32 contentHash,
        string memory title,
        uint8 docType
    ) internal returns (uint256, uint256) {
        return _addNewVersion(categoryId, documentId, contentUri, contentHash, title, "", docType);
    }

    function _buildLocalRef(uint256 cat, uint256 doc, uint256 ver, uint8 relationType, string memory targetSection)
        internal
        view
        returns (DocumentReference[] memory)
    {
        DocumentReference[] memory refs = new DocumentReference[](1);
        refs[0] = DocumentReference({
            registryAddress: address(registry),
            chainId: block.chainid,
            categoryId: cat,
            documentId: doc,
            version: ver,
            relationType: relationType,
            targetSection: targetSection
        });
        return refs;
    }

    function _attemptAmendment(
        uint256 cat,
        uint256 doc,
        uint8 docType,
        DocumentReference[] memory refs
    ) internal {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: cat,
            documentId: doc,
            contentUri: "tx_attempt",
            contentHash: HASH_B,
            title: "Attempt",
            voteId: "",
            docType: docType
        });
        vm.prank(admin);
        registry.addDocument(input, refs);
    }

    // ──────────────── Constructor ────────────────────────────

    function test_constructor_setsGovernanceAuthority() public view {
        assertEq(registry.governanceAuthority(), admin);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(BVSRegistry.InvalidAuthority.selector);
        new BVSRegistry(address(0), false);
    }

    function test_constructor_setsHardLockImmutable_softLock() public view {
        assertEq(registry.hardLock(), false);
    }

    // ──────────────── addCategory ────────────────────────────

    function test_addCategory_byAdmin() public {
        uint256 id = _createCategory("Constitutional Law");
        assertEq(id, 0);
        assertEq(registry.categoryCount(), 1);
        assertEq(registry.categoryNames(0), "Constitutional Law");
    }

    function test_addCategory_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.addCategory("Anything");
    }

    function test_addCategory_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit CategoryAdded(0, "Operational Policy");
        registry.addCategory("Operational Policy");
    }

    function test_addCategory_assignsSequentialIds() public {
        assertEq(_createCategory("A"), 0);
        assertEq(_createCategory("B"), 1);
        assertEq(_createCategory("C"), 2);
    }

    // ──────────────── addDocument: new document ──────────────

    function test_addDocument_newDocument() public {
        _createCategory("Constitutional Law");
        (uint256 docId, uint256 version) = _addNewDocument(0, "tx_a", HASH_A, "Bylaws v1", "snapshot:1", 0);

        assertEq(docId, 1);
        assertEq(version, 1);
        assertEq(registry.getDocumentCount(0), 1);
        assertEq(registry.getVersionCount(0, 1), 1);
    }

    function test_addDocument_emitsEvent() public {
        _createCategory("Cat");

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            documentId: 0,
            contentUri: "tx_a",
            contentHash: HASH_A,
            title: "Doc",
            voteId: "v1",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DocumentAdded(0, 1, 1, "tx_a", HASH_A, 0);
        registry.addDocument(input, refs);
    }

    function test_addDocument_byStranger_reverts() public {
        _createCategory("Cat");

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            documentId: 0,
            contentUri: "tx_a",
            contentHash: HASH_A,
            title: "Doc",
            voteId: "v1",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);

        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.addDocument(input, refs);
    }

    function test_addDocument_invalidCategory_reverts() public {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 99,
            documentId: 0,
            contentUri: "tx",
            contentHash: HASH_A,
            title: "Doc",
            voteId: "v1",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.CategoryDoesNotExist.selector, 99));
        registry.addDocument(input, refs);
    }

    function test_addDocument_multipleNewDocs_assignSequentialIds() public {
        _createCategory("Cat");
        (uint256 d1,) = _addNewDocument(0, "tx_a", HASH_A, "A", "v1", 0);
        (uint256 d2,) = _addNewDocument(0, "tx_b", HASH_B, "B", "v2", 0);
        (uint256 d3,) = _addNewDocument(0, "tx_c", HASH_C, "C", "v3", 0);

        assertEq(d1, 1);
        assertEq(d2, 2);
        assertEq(d3, 3);
        assertEq(registry.getDocumentCount(0), 3);
    }

    // ──────────────── addDocument: new version ───────────────

    function test_addDocument_newVersion() public {
        _createCategory("Cat");
        (uint256 docId,) = _addNewDocument(0, "tx_a", HASH_A, "A v1", "v1", 0);
        (uint256 sameDocId, uint256 version) = _addNewVersion(0, docId, "tx_b", HASH_B, "A v2", "v2", 1);

        assertEq(sameDocId, docId);
        assertEq(version, 2);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_addDocument_versionNonExistentDoc_reverts() public {
        _createCategory("Cat");
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            documentId: 99,
            contentUri: "tx",
            contentHash: HASH_A,
            title: "Doc",
            voteId: "v1",
            docType: 1
        });
        DocumentReference[] memory refs = new DocumentReference[](0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.DocumentDoesNotExist.selector, 0, 99));
        registry.addDocument(input, refs);
    }

    function test_addDocument_storesAllFields() public {
        _createCategory("Cat");
        _addNewDocument(0, "tx_a", HASH_A, "Title", "snap:abc", 0);

        Document memory doc = registry.getDocument(0, 1, 1);
        assertEq(doc.contentUri, "tx_a");
        assertEq(doc.contentHash, HASH_A);
        assertEq(doc.title, "Title");
        assertEq(doc.voteId, "snap:abc");
        assertEq(doc.docType, 0);
        assertEq(doc.version, 1);
        assertGt(doc.timestamp, 0);
    }

    // ──────────────── References ─────────────────────────────

    function test_addDocument_storesReferences() public {
        _createCategory("Cat");

        DocumentReference[] memory refs = new DocumentReference[](1);
        refs[0] = DocumentReference({
            registryAddress: address(registry),
            chainId: block.chainid,
            categoryId: 0,
            documentId: 0,
            version: 0,
            relationType: 0,
            targetSection: ""
        });

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            documentId: 0,
            contentUri: "tx",
            contentHash: HASH_A,
            title: "Doc",
            voteId: "v",
            docType: 0
        });

        vm.prank(admin);
        registry.addDocument(input, refs);

        DocumentReference[] memory stored = registry.getReferences(0, 1, 1);
        assertEq(stored.length, 1);
        assertEq(stored[0].registryAddress, address(registry));
    }

    // ──────────────── Read functions ─────────────────────────

    function test_getLatest_returnsLatestVersion() public {
        _createCategory("Cat");
        _addNewDocument(0, "tx_a", HASH_A, "v1", "vid1", 0);
        _addNewVersion(0, 1, "tx_b", HASH_B, "v2", "vid2", 1);
        _addNewVersion(0, 1, "tx_c", HASH_C, "v3", "vid3", 1);

        Document memory latest = registry.getLatest(0, 1);
        assertEq(latest.version, 3);
        assertEq(latest.contentHash, HASH_C);
    }

    function test_getHistory_returnsAllVersions() public {
        _createCategory("Cat");
        _addNewDocument(0, "tx_a", HASH_A, "v1", "vid1", 0);
        _addNewVersion(0, 1, "tx_b", HASH_B, "v2", "vid2", 1);

        Document[] memory history = registry.getHistory(0, 1);
        assertEq(history.length, 2);
        assertEq(history[0].contentHash, HASH_A);
        assertEq(history[1].contentHash, HASH_B);
    }

    function test_getDocument_invalidVersion_reverts() public {
        _createCategory("Cat");
        _addNewDocument(0, "tx", HASH_A, "v1", "vid", 0);

        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.VersionDoesNotExist.selector, 0, 1, 99));
        registry.getDocument(0, 1, 99);
    }

    // ──────────────── Governance transfer ────────────────────

    function test_setGovernanceAuthority_byAdmin() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit GovernanceAuthorityTransferred(admin, newAdmin);
        registry.setGovernanceAuthority(newAdmin);

        assertEq(registry.governanceAuthority(), newAdmin);
    }

    function test_setGovernanceAuthority_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.setGovernanceAuthority(newAdmin);
    }

    function test_setGovernanceAuthority_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(BVSRegistry.InvalidAuthority.selector);
        registry.setGovernanceAuthority(address(0));
    }

    function test_setGovernanceAuthority_oldAuthorityCannotAddCategory() public {
        vm.prank(admin);
        registry.setGovernanceAuthority(newAdmin);

        vm.prank(admin);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.addCategory("Should fail");
    }

    // ──────────────── rejectProposal ─────────────────────────

    function test_rejectProposal_byAdmin_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ProposalRejected(42, 10, 25, 3, "Out of scope");
        registry.rejectProposal(42, 10, 25, 3, "Out of scope");
    }

    function test_rejectProposal_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.rejectProposal(1, 0, 0, 0, "");
    }

    function test_rejectProposal_emptyReasonAllowed() public {
        vm.prank(admin);
        registry.rejectProposal(7, 0, 0, 0, "");
    }

    // ──────────────── Amendment Restrictions: per-doc store ──

    function test_amendmentRestrictions_perDocument() public {
        _createCategory("Resolutions");
        (uint256 doc1,) = _addNewDocument(0, "tx_1", HASH_A, "Policy A", "", 0);
        (uint256 doc2,) = _addNewDocument(0, "tx_2", HASH_B, "Policy B", "", 0);

        uint256[] memory locked = new uint256[](2);
        locked[0] = 1;
        locked[1] = 3;

        vm.prank(admin);
        registry.setAmendmentRestrictions(0, doc1, 90 days, locked);

        (uint256 minTime,, uint256[] memory storedLocked) = registry.getAmendmentRestrictions(0, doc1);
        assertEq(minTime, 90 days);
        assertEq(storedLocked.length, 2);
        assertEq(storedLocked[0], 1);
        assertEq(storedLocked[1], 3);

        (uint256 minTime2,, uint256[] memory locked2) = registry.getAmendmentRestrictions(0, doc2);
        assertEq(minTime2, 0);
        assertEq(locked2.length, 0);
    }

    function test_setAmendmentRestrictions_governanceOnly() public {
        _createCategory("Resolutions");
        _addNewDocument(0, "tx_1", HASH_A, "Policy A", "", 0);

        uint256[] memory locked = new uint256[](0);

        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernance.selector);
        registry.setAmendmentRestrictions(0, 1, 30 days, locked);

        vm.prank(admin);
        registry.setAmendmentRestrictions(0, 1, 30 days, locked);
    }

    function test_setAmendmentRestrictions_emitsEvent() public {
        _createCategory("Resolutions");
        _addNewDocument(0, "tx_1", HASH_A, "Policy A", "", 0);

        uint256[] memory locked = new uint256[](0);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit AmendmentRestrictionsUpdated(0, 1);
        registry.setAmendmentRestrictions(0, 1, 30 days, locked);
    }

    function test_setAmendmentRestrictions_revertsForNonexistentDocument() public {
        _createCategory("Resolutions");

        uint256[] memory locked = new uint256[](0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.DocumentDoesNotExist.selector, 0, 1));
        registry.setAmendmentRestrictions(0, 1, 30 days, locked);
    }

    function test_amendmentRestrictions_defaultToZero() public {
        _createCategory("Constitutional Law");
        _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        (uint256 minTime, uint256 lastTime, uint256[] memory locked) = registry.getAmendmentRestrictions(0, 1);
        assertEq(minTime, 0);
        // lastAmendmentTime only writes when minTimeBetweenAmendments > 0.
        assertEq(lastTime, 0);
        assertEq(locked.length, 0);
    }

    // ──────────────── AmendmentTooSoon (time gate) ───────────

    function test_addDocument_amendmentTooSoon_revertsWithinWindow() public {
        _createCategory("Resolutions");
        (uint256 docId,) = _addNewDocument(0, "tx_v1", HASH_A, "Policy", "", 0);

        uint256[] memory noLocks = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, noLocks);

        uint256 amendmentTime = block.timestamp;
        _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 0);

        vm.warp(amendmentTime + 15 days);

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            documentId: docId,
            contentUri: "tx_v3",
            contentHash: HASH_C,
            title: "V3",
            voteId: "",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.AmendmentTooSoon.selector, 0, docId, amendmentTime + 30 days
        ));
        registry.addDocument(input, refs);
    }

    function test_addDocument_amendmentTooSoon_passesAfterWindow() public {
        _createCategory("Resolutions");
        (uint256 docId,) = _addNewDocument(0, "tx_v1", HASH_A, "Policy", "", 0);

        uint256[] memory noLocks = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, noLocks);

        uint256 amendmentTime = block.timestamp;
        _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 0);

        vm.warp(amendmentTime + 31 days);

        (, uint256 v3) = _amendDocument(0, docId, "tx_v3", HASH_C, "V3", 0);
        assertEq(v3, 3);
    }

    function test_addDocument_amendmentTooSoon_skippedWhenThrottleDisabled() public {
        _createCategory("Resolutions");
        (uint256 docId,) = _addNewDocument(0, "tx_v1", HASH_A, "Policy", "", 0);

        // minTimeBetweenAmendments stays at 0 — guard must not fire.
        (, uint256 v2) = _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 0);
        assertEq(v2, 2);
    }

    function test_addDocument_amendmentTooSoon_firstAmendmentAfterThrottleSetPasses() public {
        _createCategory("Resolutions");
        (uint256 docId,) = _addNewDocument(0, "tx_v1", HASH_A, "Policy", "", 0);

        // Enabling the throttle after the initial add must start the clock from now —
        // lastAmendmentTime stayed at 0 because the throttle was off at add time.
        uint256[] memory noLocks = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, noLocks);

        (, uint256 v2) = _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 0);
        assertEq(v2, 2);

        (, uint256 lastTime,) = registry.getAmendmentRestrictions(0, docId);
        assertEq(lastTime, block.timestamp);
    }

    // ──────────────── lastAmendmentTime gated write ──────────

    function test_addDocument_lastAmendmentTime_staysZeroWithoutThrottle() public {
        _createCategory("Test");
        _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);
        _amendDocument(0, 1, "tx_2", HASH_B, "V2", 0);

        (, uint256 lastTime,) = registry.getAmendmentRestrictions(0, 1);
        assertEq(lastTime, 0);
    }

    function test_addDocument_lastAmendmentTime_setWithThrottle() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory noLocks = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, noLocks);

        _amendDocument(0, docId, "tx_2", HASH_B, "V2", 0);

        (, uint256 lastTime,) = registry.getAmendmentRestrictions(0, docId);
        assertEq(lastTime, block.timestamp);
    }

    // ──────────────── lockedSections enforcement ─────────────

    function test_sectionLocked_revertsOnDirectMatch() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "3");

        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.SectionLocked.selector, 0, docId, 3
        ));
        _attemptAmendment(0, docId, 1, refs);
    }

    function test_sectionLocked_subsectionResolvesToRoot() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "3.1");

        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.SectionLocked.selector, 0, docId, 3
        ));
        _attemptAmendment(0, docId, 2, refs);
    }

    function test_sectionLocked_multiTargetWithOneLocked() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 5;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "3,5,7.2");

        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.SectionLocked.selector, 0, docId, 5
        ));
        _attemptAmendment(0, docId, 1, refs);
    }

    function test_sectionLocked_unlockedSectionPasses() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "4");
        _attemptAmendment(0, docId, 1, refs);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_sectionLocked_skippedForOriginalDocType() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        // docType = 0 (Original) is not in the amendment family; the check must not fire
        // even when the targetSection syntactically matches a locked section.
        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "3");
        _attemptAmendment(0, docId, 0, refs);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_sectionLocked_skippedForEmptyTargetSection() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "");
        _attemptAmendment(0, docId, 1, refs);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_sectionLocked_skippedWhenRefsEmpty() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        // Traditional amend-by-version pattern — no refs, no targetSection, no check.
        _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 1);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_sectionLocked_skippedWhenRefsPointToOtherRegistry() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 3;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        // refs[0] points at some other registry — local locks do not apply across registries.
        DocumentReference[] memory refs = new DocumentReference[](1);
        refs[0] = DocumentReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            documentId: docId,
            version: 1,
            relationType: 0,
            targetSection: "3"
        });
        _attemptAmendment(0, docId, 1, refs);
        assertEq(registry.getVersionCount(0, docId), 2);
    }

    function test_sectionLocked_revertsForRepealDocType() public {
        _createCategory("Test");
        (uint256 docId,) = _addNewDocument(0, "tx_1", HASH_A, "Doc", "", 0);

        uint256[] memory locked = new uint256[](1);
        locked[0] = 7;
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        DocumentReference[] memory refs = _buildLocalRef(0, docId, 1, 0, "7");

        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.SectionLocked.selector, 0, docId, 7
        ));
        _attemptAmendment(0, docId, 3, refs);
    }

    // ──────────────── Soft-lock semantics ────────────────────

    function test_softLock_adminCanOverwriteRestrictionsMidWindow() public {
        _createCategory("Resolutions");
        (uint256 docId,) = _addNewDocument(0, "tx_v1", HASH_A, "Policy", "", 0);

        uint256[] memory noLocks = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, noLocks);

        // Trigger the clock by amending v1 → v2.
        _amendDocument(0, docId, "tx_v2", HASH_B, "V2", 0);

        // Mid-window: in soft-lock, admin can clear or replace restrictions freely.
        vm.warp(block.timestamp + 5 days);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, noLocks);

        (uint256 minTime,,) = registry.getAmendmentRestrictions(0, docId);
        assertEq(minTime, 0);
    }
}

// ─────────────────────────────────────────────────────────────
// Hard-lock variant — admin self-binds; setAmendmentRestrictions
// reverts RestrictionsLocked while a window is active.
// ─────────────────────────────────────────────────────────────

contract BVSRegistryHardLockTest is Test {
    BVSRegistry registry;

    address admin = makeAddr("admin");

    bytes32 constant HASH_A = keccak256("document-a");
    bytes32 constant HASH_B = keccak256("document-b");

    function setUp() public {
        registry = new BVSRegistry(admin, true);
    }

    function _createCategory(string memory name) internal returns (uint256) {
        vm.prank(admin);
        return registry.addCategory(name);
    }

    function _addNewDocument(uint256 categoryId, string memory title) internal returns (uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: categoryId,
            documentId: 0,
            contentUri: "tx",
            contentHash: HASH_A,
            title: title,
            voteId: "",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);
        vm.prank(admin);
        (uint256 docId,) = registry.addDocument(input, refs);
        return docId;
    }

    function _amend(uint256 cat, uint256 doc) internal {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: cat,
            documentId: doc,
            contentUri: "tx2",
            contentHash: HASH_B,
            title: "V2",
            voteId: "",
            docType: 0
        });
        DocumentReference[] memory refs = new DocumentReference[](0);
        vm.prank(admin);
        registry.addDocument(input, refs);
    }

    function test_constructor_setsHardLockImmutable_hardLock() public view {
        assertEq(registry.hardLock(), true);
    }

    function test_hardLock_setRestrictions_succeedsBeforeAnyAmendment() public {
        _createCategory("Cat");
        uint256 docId = _addNewDocument(0, "Doc");

        // No lastAmendmentTime yet — even hard-lock allows the initial set.
        uint256[] memory locked = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, locked);

        (uint256 minTime,,) = registry.getAmendmentRestrictions(0, docId);
        assertEq(minTime, 30 days);
    }

    function test_hardLock_setRestrictions_revertsMidWindow() public {
        _createCategory("Cat");
        uint256 docId = _addNewDocument(0, "Doc");

        uint256[] memory locked = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, locked);

        // Trigger lastAmendmentTime by adding v2.
        uint256 amendmentTime = block.timestamp;
        _amend(0, docId);

        // Inside the 30-day window — admin cannot change/clear restrictions.
        vm.warp(amendmentTime + 5 days);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            BVSRegistry.RestrictionsLocked.selector, 0, docId, amendmentTime + 30 days
        ));
        registry.setAmendmentRestrictions(0, docId, 0, locked);
    }

    function test_hardLock_setRestrictions_succeedsAfterWindowElapses() public {
        _createCategory("Cat");
        uint256 docId = _addNewDocument(0, "Doc");

        uint256[] memory locked = new uint256[](0);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 30 days, locked);

        uint256 amendmentTime = block.timestamp;
        _amend(0, docId);

        vm.warp(amendmentTime + 31 days);
        vm.prank(admin);
        registry.setAmendmentRestrictions(0, docId, 0, locked);

        (uint256 minTime,,) = registry.getAmendmentRestrictions(0, docId);
        assertEq(minTime, 0);
    }
}
