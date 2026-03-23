// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BVSToken} from "../src/BVSToken.sol";
import {BVSRegistry} from "../src/BVSRegistry.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";

/// @dev Mock verifier that approves only whitelisted addresses.
contract MockVerifier is IVerifier {
    mapping(address => bool) public approved;

    function setApproved(address account, bool status) external {
        approved[account] = status;
    }

    function isVerified(address account) external view override returns (bool) {
        return approved[account];
    }
}

/// @title Forward Compatibility Tests (US3)
/// @notice Verify that all forward-compatibility fields are present, stored,
///         and retrievable — even though BVS mode does not actively use them.
contract ForwardCompatTest is Test {
    BVSToken token;
    BVSRegistry registry;
    MockVerifier verifier;

    address admin = makeAddr("admin");
    address authority = makeAddr("authority");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant HASH_A = keccak256("forward-compat-a");
    bytes32 constant HASH_B = keccak256("forward-compat-b");
    bytes constant CREDENTIAL = hex"deadbeef";

    function setUp() public {
        token = new BVSToken(admin, true, true);
        registry = new BVSRegistry(authority);
        verifier = new MockVerifier();

        vm.prank(authority);
        registry.addCategory("Constitutional Law");
    }

    // ──────────────── Helpers ────────────────────────────────

    function _addDocument(
        string memory arweaveTxId,
        bytes32 contentHash,
        string memory title,
        uint8 docType
    ) internal returns (uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            title: title,
            voteId: "",
            docType: docType
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);
        vm.prank(authority);
        return registry.addDocument(input, refs);
    }

    function _addDocumentWithRefs(
        string memory arweaveTxId,
        bytes32 contentHash,
        string memory title,
        uint8 docType,
        BVSRegistry.ExternalReference[] memory refs
    ) internal returns (uint256) {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            title: title,
            voteId: "",
            docType: docType
        });
        vm.prank(authority);
        return registry.addDocument(input, refs);
    }

    // ──────────────── Scenario 1: docType = 0 round-trip ─────

    function test_docType0_storedAndRetrieved() public {
        uint256 v = _addDocument("tx_dt0", HASH_A, "Legislation", 0);

        BVSRegistry.Document memory doc = registry.getDocument(0, v);
        assertEq(doc.docType, 0);
    }

    // ──────────────── Scenario 2: docType = 1 round-trip ─────

    function test_docType1_storedAndRetrieved() public {
        uint256 v = _addDocument("tx_dt1", HASH_A, "Amendment", 1);

        BVSRegistry.Document memory doc = registry.getDocument(0, v);
        assertEq(doc.docType, 1);
    }

    function test_docType_mixedInSameCategory() public {
        uint256 v1 = _addDocument("tx_leg", HASH_A, "Legislation", 0);
        uint256 v2 = _addDocument("tx_amd", HASH_B, "Amendment", 1);

        assertEq(registry.getDocument(0, v1).docType, 0);
        assertEq(registry.getDocument(0, v2).docType, 1);
    }

    function test_docType_emittedInEvent() public {
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_evt",
            contentHash: HASH_A,
            title: "Event Test",
            voteId: "",
            docType: 1
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        vm.expectEmit(true, true, false, true);
        emit BVSRegistry.DocumentAdded(0, 1, "tx_evt", HASH_A, 1);
        registry.addDocument(input, refs);
    }

    // ──────────────── Scenario 3: relationType = 0 (GOVERNS) ─

    function test_relationType0_governs_storedAndRetrieved() public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](1);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 0, // GOVERNS
            targetSection: ""
        });

        uint256 v = _addDocumentWithRefs("tx_gov", HASH_A, "Governing Doc", 0, refs);

        BVSRegistry.ExternalReference[] memory stored = registry.getReferences(0, v);
        assertEq(stored.length, 1);
        assertEq(stored[0].relationType, 0);
        assertEq(stored[0].registryAddress, address(0xBEEF));
    }

    // ──────────────── Scenario 4: All relationTypes 0–4 ──────

    function test_allRelationTypes_storedAndRetrieved() public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](5);

        // 0 = AMENDS, 1 = REVISES, 2 = REPEALS, 3 = CODIFIES, 4 = GOVERNS
        for (uint8 i = 0; i < 5; i++) {
            refs[i] = BVSRegistry.ExternalReference({
                registryAddress: address(uint160(0x1000 + i)),
                chainId: block.chainid,
                categoryId: i,
                version: i + 1,
                relationType: i,
                targetSection: ""
            });
        }

        uint256 v = _addDocumentWithRefs("tx_all_rel", HASH_A, "All Relations", 0, refs);

        BVSRegistry.ExternalReference[] memory stored = registry.getReferences(0, v);
        assertEq(stored.length, 5);
        for (uint8 i = 0; i < 5; i++) {
            assertEq(stored[i].relationType, i);
            assertEq(stored[i].registryAddress, address(uint160(0x1000 + i)));
            assertEq(stored[i].categoryId, i);
            assertEq(stored[i].version, i + 1);
        }
    }

    function test_relationType_persistsAcrossVersions() public {
        BVSRegistry.ExternalReference[] memory refs1 = new BVSRegistry.ExternalReference[](1);
        refs1[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xAAAA),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 0, // AMENDS
            targetSection: "1.3"
        });

        BVSRegistry.ExternalReference[] memory refs2 = new BVSRegistry.ExternalReference[](1);
        refs2[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBBBB),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 1, // REVISES
            targetSection: ""
        });

        uint256 v1 = _addDocumentWithRefs("tx_r1", HASH_A, "Doc V1", 0, refs1);
        uint256 v2 = _addDocumentWithRefs("tx_r2", HASH_B, "Doc V2", 0, refs2);

        assertEq(registry.getReferences(0, v1)[0].relationType, 0);
        assertEq(registry.getReferences(0, v1)[0].targetSection, "1.3");
        assertEq(registry.getReferences(0, v2)[0].relationType, 1);
        assertEq(registry.getReferences(0, v2)[0].targetSection, "");
    }

    // ──────────────── Scenario 5: Verifier set/gate ──────────

    function test_verifier_setByAdmin() public {
        vm.prank(admin);
        token.setVerifier(address(verifier));

        assertEq(address(token.verifier()), address(verifier));
    }

    function test_verifier_gatesMinting() public {
        vm.prank(admin);
        token.setVerifier(address(verifier));

        // Unapproved address — mint should revert
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BVSToken.VerifierRejected.selector, alice));
        token.mint(alice, CREDENTIAL);

        // Approve and retry — should succeed
        verifier.setApproved(alice, true);
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);
        assertEq(token.ownerOf(0), alice);
    }

    function test_verifier_noVerifierAllowsAll() public {
        assertEq(address(token.verifier()), address(0));

        vm.prank(admin);
        token.mint(alice, CREDENTIAL);
        assertEq(token.ownerOf(0), alice);
    }

    function test_verifier_removedWithZeroAddress() public {
        vm.startPrank(admin);
        token.setVerifier(address(verifier));
        token.setVerifier(address(0));
        vm.stopPrank();

        assertEq(address(token.verifier()), address(0));

        // Should mint without verification
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);
        assertEq(token.ownerOf(0), alice);
    }

    // ──────────────── Scenario 6: Amendment restrictions passthrough ──

    function test_amendmentRestrictions_defaultDoNotBlock() public {
        // No restrictions set — addDocument should succeed freely
        _addDocument("tx_no_restrict_1", HASH_A, "First", 0);
        uint256 v2 = _addDocument("tx_no_restrict_2", HASH_B, "Second", 0);

        assertEq(v2, 2);
    }

    function test_amendmentRestrictions_zeroMinTimeDoesNotBlock() public {
        // Explicitly set minTime = 0 — should not block
        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 0, locked, 0);

        _addDocument("tx_z1", HASH_A, "First", 0);
        uint256 v2 = _addDocument("tx_z2", HASH_B, "Immediate Second", 0);
        assertEq(v2, 2);
    }

    function test_amendmentRestrictions_timeWindowEnforced() public {
        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 7 days, locked, 0);

        _addDocument("tx_tw1", HASH_A, "First", 0);

        // Immediate second should revert
        BVSRegistry.DocumentInput memory input = BVSRegistry.DocumentInput({
            categoryId: 0,
            arweaveTxId: "tx_tw2",
            contentHash: HASH_B,
            title: "Too Soon",
            voteId: "",
            docType: 0
        });
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](0);

        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(BVSRegistry.AmendmentTooSoon.selector, 0, block.timestamp + 7 days)
        );
        registry.addDocument(input, refs);

        // After time window passes — should succeed
        vm.warp(block.timestamp + 7 days);
        vm.prank(authority);
        uint256 v2 = registry.addDocument(input, refs);
        assertEq(v2, 2);
    }

    // ──────────────── Scenario 7: Amendment restriction fields round-trip ─
    // Note: Reference docs mention optional document-level char/word count and
    // section lock flags, but these were excluded per system spec §3.2.
    // lockedSections and coreThreshold live at the category level in
    // AmendmentRestrictions. This is the correct and final design.

    function test_lockedSections_roundTrip() public {
        uint256[] memory sections = new uint256[](4);
        sections[0] = 1;
        sections[1] = 3;
        sections[2] = 7;
        sections[3] = 12;

        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 0, sections, 0);

        (,, uint256[] memory stored,) = registry.getAmendmentRestrictions(0);
        assertEq(stored.length, 4);
        assertEq(stored[0], 1);
        assertEq(stored[1], 3);
        assertEq(stored[2], 7);
        assertEq(stored[3], 12);
    }

    function test_coreThreshold_roundTrip() public {
        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 0, locked, 75);

        (,,, uint256 threshold) = registry.getAmendmentRestrictions(0);
        assertEq(threshold, 75);
    }

    function test_allOptionalFields_combinedRoundTrip() public {
        uint256[] memory sections = new uint256[](2);
        sections[0] = 0;
        sections[1] = 5;

        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 90 days, sections, 90);

        (uint256 minTime, uint256 lastTime, uint256[] memory stored, uint256 threshold) =
            registry.getAmendmentRestrictions(0);

        assertEq(minTime, 90 days);
        assertEq(lastTime, 0); // No documents added yet
        assertEq(stored.length, 2);
        assertEq(stored[0], 0);
        assertEq(stored[1], 5);
        assertEq(threshold, 90);
    }

    function test_optionalFields_overwritable() public {
        uint256[] memory sections1 = new uint256[](2);
        sections1[0] = 1;
        sections1[1] = 2;

        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 30 days, sections1, 50);

        // Overwrite with different values
        uint256[] memory sections2 = new uint256[](1);
        sections2[0] = 99;

        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 60 days, sections2, 80);

        (uint256 minTime,, uint256[] memory stored, uint256 threshold) =
            registry.getAmendmentRestrictions(0);

        assertEq(minTime, 60 days);
        assertEq(stored.length, 1);
        assertEq(stored[0], 99);
        assertEq(threshold, 80);
    }

    function test_optionalFields_emptyLockedSections() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 0, empty, 0);

        (uint256 minTime,, uint256[] memory stored, uint256 threshold) =
            registry.getAmendmentRestrictions(0);

        assertEq(minTime, 0);
        assertEq(stored.length, 0);
        assertEq(threshold, 0);
    }

    // ──────────────── Fuzz: docType any uint8 ────────────────

    function testFuzz_docType_anyValue(uint8 docType) public {
        uint256 v = _addDocument("tx_fuzz_dt", HASH_A, "Fuzz DocType", docType);
        assertEq(registry.getDocument(0, v).docType, docType);
    }

    // ──────────────── Fuzz: relationType any uint8 ───────────

    function testFuzz_relationType_anyValue(uint8 relationType) public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](1);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xDEAD),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: relationType,
            targetSection: "2.1.A"
        });

        uint256 v = _addDocumentWithRefs("tx_fuzz_rt", HASH_A, "Fuzz RelType", 0, refs);
        assertEq(registry.getReferences(0, v)[0].relationType, relationType);
        assertEq(registry.getReferences(0, v)[0].targetSection, "2.1.A");
    }

    // ──────────────── targetSection round-trip ─────────────────

    function test_targetSection_emptyStringForWholeDocument() public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](1);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 0,
            targetSection: ""
        });

        uint256 v = _addDocumentWithRefs("tx_ts_empty", HASH_A, "Whole Doc Ref", 0, refs);
        assertEq(registry.getReferences(0, v)[0].targetSection, "");
    }

    function test_targetSection_specificSection() public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](1);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 0,
            targetSection: "1.4"
        });

        uint256 v = _addDocumentWithRefs("tx_ts_sec", HASH_A, "Section Ref", 0, refs);
        assertEq(registry.getReferences(0, v)[0].targetSection, "1.4");
    }

    function test_targetSection_multipleCommaSeparated() public {
        BVSRegistry.ExternalReference[] memory refs = new BVSRegistry.ExternalReference[](1);
        refs[0] = BVSRegistry.ExternalReference({
            registryAddress: address(0xBEEF),
            chainId: block.chainid,
            categoryId: 0,
            version: 1,
            relationType: 2,
            targetSection: "1,2.1,3"
        });

        uint256 v = _addDocumentWithRefs("tx_ts_multi", HASH_A, "Multi Section", 0, refs);
        assertEq(registry.getReferences(0, v)[0].targetSection, "1,2.1,3");
    }

    // ──────────────── Fuzz: coreThreshold any uint256 ────────

    function testFuzz_coreThreshold_anyValue(uint256 threshold) public {
        uint256[] memory locked = new uint256[](0);
        vm.prank(authority);
        registry.setAmendmentRestrictions(0, 0, locked, threshold);

        (,,, uint256 stored) = registry.getAmendmentRestrictions(0);
        assertEq(stored, threshold);
    }
}
