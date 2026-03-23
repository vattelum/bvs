// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BVSRegistry} from "../src/BVSRegistry.sol";

contract BVSRegistryTest is Test {
    BVSRegistry registry;

    address authority = makeAddr("authority");
    address stranger = makeAddr("stranger");
    address newAuthority = makeAddr("newAuthority");

    bytes32 constant HASH_A = keccak256("document-a");
    bytes32 constant HASH_B = keccak256("document-b");
    bytes32 constant HASH_C = keccak256("document-c");

    event CategoryAdded(uint256 indexed categoryId, string name);
    event DocumentAdded(
        uint256 indexed categoryId,
        uint256 indexed version,
        string arweaveTxId,
        bytes32 contentHash,
        uint8 docType
    );
    event GovernanceAuthorityTransferred(address indexed previous, address indexed current);
    event AmendmentRestrictionsUpdated(uint256 indexed categoryId);

    function setUp() public {
        registry = new BVSRegistry(authority);
    }

    // ──────────────── Helpers ────────────────────────────────

    function _createCategory(string memory name) internal returns (uint256) {
        vm.prank(authority);
        return registry.addCategory(name);
    }

    function _addDocument(
        uint256 categoryId,
        string memory arweaveTxId,
        bytes32 contentHash,
        string memory title,
        string memory voteId_,
        uint8 docType
    ) internal returns (uint256) {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);
        return _addDocumentWithRefs(categoryId, arweaveTxId, contentHash, title, voteId_, docType, refs);
    }

    function _addDocumentWithRefs(
        uint256 categoryId,
        string memory arweaveTxId,
        bytes32 contentHash,
        string memory title,
        string memory voteId_,
        uint8 docType,
        BVSRegistry.ExternalReference[] memory refs
    ) internal returns (uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: categoryId,
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            title: title,
            voteId: voteId_,
            docType: docType
        });
        vm.prank(authority);
        return registry.addDocument(input, refs);
    }

    // ──────────────── Scenario 1: addCategory ───────────────

    function test_addCategory_createsWithSequentialId() public {
        uint256 id0 = _createCategory("Constitutional Law");
        uint256 id1 = _createCategory("Trade Regulations");

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(registry.categoryCount(), 2);
        assertEq(registry.categoryNames(0), "Constitutional Law");
        assertEq(registry.categoryNames(1), "Trade Regulations");
    }

    function test_addCategory_emitsEvent() public {
        vm.prank(authority);
        vm.expectEmit(true, false, false, true);
        emit CategoryAdded(0, "Constitutional Law");
        registry.addCategory("Constitutional Law");
    }

    // ──────────────── Scenario 2: addDocument ───────────────

    function test_addDocument_storesAllFields() public {
        _createCategory("Constitutional Law");
        uint256 version = _addDocument(0, "tx_abc123", HASH_A, "Article 1", "snapshot-001", 0);

        assertEq(version, 1);

        BVSRegistry.Document memory doc = registry.getDocument(0, 1);
        assertEq(doc.arweaveTxId, "tx_abc123");
        assertEq(doc.contentHash, HASH_A);
        assertEq(doc.title, "Article 1");
        assertEq(doc.version, 1);
        assertEq(doc.timestamp, block.timestamp);
        assertEq(doc.voteId, "snapshot-001");
        assertEq(doc.docType, 0);
    }

    function test_addDocument_emitsEvent() public {
        _createCategory("Constitutional Law");

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_abc123",
            contentHash: HASH_A,
            title: "Article 1",
            voteId: "snapshot-001",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        vm.expectEmit(true, true, false, true);
        emit DocumentAdded(0, 1, "tx_abc123", HASH_A, 0);
        registry.addDocument(input, refs);
    }

    // ──────────────── Scenario 3: Version auto-increment ────

    function test_addDocument_autoIncrementsVersion() public {
        _createCategory("Constitutional Law");

        uint256 v1 = _addDocument(0, "tx_1", HASH_A, "Version 1", "", 0);
        uint256 v2 = _addDocument(0, "tx_2", HASH_B, "Version 2", "", 0);

        assertEq(v1, 1);
        assertEq(v2, 2);
        assertEq(registry.getVersionCount(0), 2);

        assertEq(registry.getDocument(0, 1).title, "Version 1");
        assertEq(registry.getDocument(0, 2).title, "Version 2");
    }

    // ──────────────── Scenario 4: getDocument ───────────────

    function test_getDocument_returnsCorrectVersion() public {
        _createCategory("Trade Regulations");

        _addDocument(0, "tx_1", HASH_A, "Draft", "", 0);
        _addDocument(0, "tx_2", HASH_B, "Final", "snap-99", 0);

        BVSRegistry.Document memory draft = registry.getDocument(0, 1);
        BVSRegistry.Document memory final_ = registry.getDocument(0, 2);

        assertEq(draft.title, "Draft");
        assertEq(final_.title, "Final");
        assertEq(final_.voteId, "snap-99");
    }

    function test_getDocument_revertsForNonexistentCategory() public {
        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.CategoryDoesNotExist.selector, 99));
        registry.getDocument(99, 1);
    }

    function test_getDocument_revertsForNonexistentVersion() public {
        _createCategory("Empty");

        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.VersionDoesNotExist.selector, 0, 5));
        registry.getDocument(0, 5);
    }

    function test_getDocument_revertsForVersionZero() public {
        _createCategory("Empty");

        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.VersionDoesNotExist.selector, 0, 0));
        registry.getDocument(0, 0);
    }

    // ──────────────── Scenario 5: getLatest ─────────────────

    function test_getLatest_returnsMostRecentVersion() public {
        _createCategory("Constitutional Law");

        _addDocument(0, "tx_old", HASH_A, "Old", "", 0);
        _addDocument(0, "tx_new", HASH_B, "New", "", 0);

        BVSRegistry.Document memory latest = registry.getLatest(0);
        assertEq(latest.title, "New");
        assertEq(latest.version, 2);
    }

    function test_getLatest_revertsForEmptyCategory() public {
        _createCategory("Empty");

        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.VersionDoesNotExist.selector, 0, 0));
        registry.getLatest(0);
    }

    // ──────────────── Scenario 6: getHistory ────────────────

    function test_getHistory_returnsAllVersionsInOrder() public {
        _createCategory("Constitutional Law");

        _addDocument(0, "tx_1", HASH_A, "V1", "", 0);
        _addDocument(0, "tx_2", HASH_B, "V2", "", 0);
        _addDocument(0, "tx_3", HASH_C, "V3", "", 0);

        BVSRegistry.Document[] memory history = registry.getHistory(0);

        assertEq(history.length, 3);
        assertEq(history[0].title, "V1");
        assertEq(history[0].version, 1);
        assertEq(history[1].title, "V2");
        assertEq(history[1].version, 2);
        assertEq(history[2].title, "V3");
        assertEq(history[2].version, 3);
    }

    function test_getHistory_returnsEmptyForCategoryWithNoDocuments() public {
        _createCategory("Empty");

        BVSRegistry.Document[] memory history = registry.getHistory(0);
        assertEq(history.length, 0);
    }

    // ──────────────── Scenario 7: getReferences ─────────────

    function test_getReferences_returnsStoredReferences() public {
        _createCategory("Constitutional Law");

        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](2);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 0, // GOVERNS
            targetSection: ""
        });
        refs[1] = BVSRegistry.ExternalReference({
            registryAddress: address(0xCAFE),
            chainId: block.chainid,
            categoryId: 2,
            version: 3,
            relationType: 4, // REFERENCES
            targetSection: ""
        });

        _addDocumentWithRefs(0, "tx_ref", HASH_A, "With Refs", "", 0, refs);

        BVSRegistry.ExternalReference[] memory stored = registry.getReferences(0, 1);
        assertEq(stored.length, 2);
        assertEq(stored[0].registryAddress, address(0xBEEF));
        assertEq(stored[0].categoryId, 0);
        assertEq(stored[0].version, 1);
        assertEq(stored[0].relationType, 0);
        assertEq(stored[1].registryAddress, address(0xCAFE));
        assertEq(stored[1].relationType, 4);
    }

    function test_getReferences_returnsEmptyWhenNone() public {
        _createCategory("Constitutional Law");
        _addDocument(0, "tx_1", HASH_A, "No Refs", "", 0);

        BVSRegistry.ExternalReference[] memory refs = registry.getReferences(0, 1);
        assertEq(refs.length, 0);
    }

    // ──────────────── Scenario 8: setGovernanceAuthority ────

    function test_setGovernanceAuthority_transfersAuthority() public {
        vm.prank(authority);
        registry.setGovernanceAuthority(newAuthority);

        assertEq(registry.governanceAuthority(), newAuthority);
    }

    function test_setGovernanceAuthority_emitsEvent() public {
        vm.prank(authority);
        vm.expectEmit(true, true, false, false);
        emit GovernanceAuthorityTransferred(authority, newAuthority);
        registry.setGovernanceAuthority(newAuthority);
    }

    function test_setGovernanceAuthority_oldAuthorityLosesAccess() public {
        vm.prank(authority);
        registry.setGovernanceAuthority(newAuthority);

        vm.prank(authority);
        vm.expectRevert(BVSRegistry.NotGovernanceAuthority.selector);
        registry.addCategory("Should Fail");
    }

    function test_setGovernanceAuthority_newAuthorityCanWrite() public {
        vm.prank(authority);
        registry.setGovernanceAuthority(newAuthority);

        vm.prank(newAuthority);
        uint256 id = registry.addCategory("New Authority Category");
        assertEq(id, 0);
    }

    function test_setGovernanceAuthority_revertsForZeroAddress() public {
        vm.prank(authority);
        vm.expectRevert(BVSRegistry.InvalidGovernanceAuthority.selector);
        registry.setGovernanceAuthority(address(0));
    }

    // ──────────────── Scenario 9: Governance-only writes ────

    function test_addCategory_revertsForNonAuthority() public {
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernanceAuthority.selector);
        registry.addCategory("Unauthorized");
    }

    function test_addDocument_revertsForNonAuthority() public {
        _createCategory("Constitutional Law");

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_hack",
            contentHash: HASH_A,
            title: "Unauthorized",
            voteId: "",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernanceAuthority.selector);
        registry.addDocument(input, refs);
    }

    function test_setGovernanceAuthority_revertsForNonAuthority() public {
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernanceAuthority.selector);
        registry.setGovernanceAuthority(stranger);
    }

    function test_addDocument_revertsForNonexistentCategory() public {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 99,
            arweaveTxId: "tx_1",
            contentHash: HASH_A,
            title: "Bad Category",
            voteId: "",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(BVSRegistry.CategoryDoesNotExist.selector, 99));
        registry.addDocument(input, refs);
    }

    // ──────────────── Constructor ───────────────────────────

    function test_constructor_setsGovernanceAuthority() public view {
        assertEq(registry.governanceAuthority(), authority);
    }

    function test_constructor_revertsForZeroAddress() public {
        vm.expectRevert(BVSRegistry.InvalidGovernanceAuthority.selector);
        new BVSRegistry(address(0));
    }

    // ──────────────── Multiple Categories ───────────────────

    function test_documentsAcrossCategoriesAreIndependent() public {
        _createCategory("Category A");
        _createCategory("Category B");

        _addDocument(0, "tx_a1", HASH_A, "Cat A Doc 1", "", 0);
        _addDocument(1, "tx_b1", HASH_B, "Cat B Doc 1", "", 0);
        _addDocument(0, "tx_a2", HASH_C, "Cat A Doc 2", "", 0);

        assertEq(registry.getVersionCount(0), 2);
        assertEq(registry.getVersionCount(1), 1);
        assertEq(registry.getDocument(0, 2).title, "Cat A Doc 2");
        assertEq(registry.getDocument(1, 1).title, "Cat B Doc 1");
    }

    // ──────────────── Amendment Restrictions ────────────────

    function test_amendmentRestrictions_defaultToZero() public {
        _createCategory("Constitutional Law");

        (uint256 minTime, uint256 lastTime, uint256[] memory locked, uint256 threshold) =
            registry.getAmendmentRestrictions(0);

        assertEq(minTime, 0);
        assertEq(lastTime, 0);
        assertEq(locked.length, 0);
        assertEq(threshold, 0);
    }

    function test_setAmendmentRestrictions_storesValues() public {
        _createCategory("Constitutional Law");

        uint256[] memory locked = new uint256[](3);
        locked[0] = 1;
        locked[1] = 2;
        locked[2] = 5;

        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 90 days, locked, 90);

        (uint256 minTime,, uint256[] memory storedLocked, uint256 threshold) =
            registry.getAmendmentRestrictions(0);

        assertEq(minTime, 90 days);
        assertEq(threshold, 90);
        assertEq(storedLocked.length, 3);
        assertEq(storedLocked[0], 1);
        assertEq(storedLocked[1], 2);
        assertEq(storedLocked[2], 5);
    }

    function test_setAmendmentRestrictions_emitsEvent() public {
        _createCategory("Constitutional Law");

        uint256[] memory locked = new uint256[](0);

        vm.prank(authority);
        vm.expectEmit(true, false, false, false);
        emit AmendmentRestrictionsUpdated(0);
        registry.setAmendmentRestrictions(0, 30 days, locked, 75);
    }

    function test_amendmentRestrictions_enforcesTimeWindow() public {
        _createCategory("Constitutional Law");

        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 30 days, locked, 0);

        _addDocument(0, "tx_1", HASH_A, "First", "", 0);

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_2",
            contentHash: HASH_B,
            title: "Too Soon",
            voteId: "",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(BVSRegistry.AmendmentTooSoon.selector, 0, block.timestamp + 30 days)
        );
        registry.addDocument(input, refs);
    }

    function test_amendmentRestrictions_allowsAfterTimeWindow() public {
        _createCategory("Constitutional Law");

        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 30 days, locked, 0);

        _addDocument(0, "tx_1", HASH_A, "First", "", 0);

        vm.warp(block.timestamp + 30 days);

        uint256 v2 = _addDocument(0, "tx_2", HASH_B, "After Window", "", 0);
        assertEq(v2, 2);
    }

    function test_setAmendmentRestrictions_revertsForNonAuthority() public {
        _createCategory("Constitutional Law");

        uint256[] memory locked = new uint256[](0);
        vm.prank(stranger);
        vm.expectRevert(BVSRegistry.NotGovernanceAuthority.selector);
        registry.setAmendmentRestrictions(0, 30 days, locked, 0);
    }

    // ──────────────── Gas Estimation ────────────────────────

    function test_gas_addCategory() public {
        vm.prank(authority);
        uint256 gasBefore = gasleft();
        registry.addCategory("Constitutional Law");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used for addCategory", gasUsed);
    }

    function test_gas_addDocument() public {
        _createCategory("Constitutional Law");

        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_abc123xyz",
            contentHash: HASH_A,
            title: "Article 1: Fundamental Rights",
            voteId: "snapshot-001",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        uint256 gasBefore = gasleft();
        registry.addDocument(input, refs);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used for addDocument", gasUsed);
    }

    // ──────────────── Fuzz Tests ────────────────────────────

    function testFuzz_addDocument_arbitraryDocType(uint8 docType) public {
        _createCategory("Test");
        uint256 v = _addDocument(0, "tx_fuzz", HASH_A, "Fuzz", "", docType);

        assertEq(registry.getDocument(0, v).docType, docType);
    }

    function testFuzz_addCategory_arbitraryName(string calldata name) public {
        vm.prank(authority);
        uint256 id = registry.addCategory(name);

        assertEq(registry.categoryNames(id), name);
    }
}
