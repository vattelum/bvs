// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BVSToken} from "../src/BVSToken.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IERC5192} from "../src/interfaces/IERC5192.sol";

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

contract BVSTokenTest is Test {
    BVSToken token;
    MockVerifier verifier;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes constant CREDENTIAL = hex"deadbeef";
    bytes constant EMPTY_CREDENTIAL = "";

    event Minted(address indexed to, uint256 indexed tokenId);
    event Burned(address indexed from, uint256 indexed tokenId);
    event Locked(uint256 tokenId);
    event VerifierSet(address indexed verifier);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function setUp() public {
        token = new BVSToken(admin, true, true);
        verifier = new MockVerifier();
    }

    // ──────────────────────── Scenario 1: Admin mints with credential ────

    function test_mint_storesCredentialAndMintsToken() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        assertEq(token.ownerOf(0), alice);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.getCredential(0), CREDENTIAL);
    }

    function test_mint_emitsEvents() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit Transfer(address(0), alice, 0);
        vm.expectEmit(true, false, false, false);
        emit Locked(0);
        vm.expectEmit(true, true, false, false);
        emit Minted(alice, 0);
        token.mint(alice, CREDENTIAL);
    }

    // ──────────────────────── Scenario 2: Transfer reverts (soulbound) ───

    function test_transferFrom_reverts() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        vm.expectRevert(BVSToken.Soulbound.selector);
        token.transferFrom(alice, bob, 0);
    }

    function test_safeTransferFrom_reverts() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        vm.expectRevert(BVSToken.Soulbound.selector);
        token.safeTransferFrom(alice, bob, 0);
    }

    // ──────────────────────── Scenario 3: locked() returns true ──────────

    function test_locked_returnsTrue() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        assertTrue(token.locked(0));
    }

    function test_locked_revertsForNonexistentToken() public {
        vm.expectRevert();
        token.locked(999);
    }

    // ──────────────────────── Scenario 4: Holder burns own token ─────────

    function test_burn_byHolder() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        token.burn(0);

        vm.expectRevert();
        token.ownerOf(0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_burn_emitsEvent() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit Burned(alice, 0);
        token.burn(0);
    }

    function test_burn_deletesCredential() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        token.burn(0);

        vm.expectRevert();
        token.getCredential(0);
    }

    // ──────────────────────── Scenario 5: Burn authorization ─────────────

    function test_burn_byNonHolder_reverts() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(bob);
        vm.expectRevert(BVSToken.NotAuthorizedToBurn.selector);
        token.burn(0);
    }

    function test_burn_byAdmin_whenEnabled() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(admin);
        token.burn(0);

        vm.expectRevert();
        token.ownerOf(0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_burn_byAdmin_emitsHolderAddress() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit Burned(alice, 0);
        token.burn(0);
    }

    function test_burn_byAdmin_whenDisabled_reverts() public {
        BVSToken noAdminBurn = new BVSToken(admin, true, false);

        vm.prank(admin);
        noAdminBurn.mint(alice, CREDENTIAL);

        vm.prank(admin);
        vm.expectRevert(BVSToken.NotAuthorizedToBurn.selector);
        noAdminBurn.burn(0);
    }

    function test_burn_adminCanBurn_immutableFlag() public view {
        assertTrue(token.adminCanBurn());
    }

    // ──────────────────────── Scenario 6: getCredential returns data ─────

    function test_getCredential_returnsStoredData() public {
        bytes memory cred = abi.encodePacked("email:sha256:abcdef1234567890");

        vm.prank(admin);
        token.mint(alice, cred);

        assertEq(token.getCredential(0), cred);
    }

    function test_getCredential_revertsForNonexistentToken() public {
        vm.expectRevert();
        token.getCredential(999);
    }

    // ──────────────────────── Scenario 7: No verifier — mint proceeds ───

    function test_mint_noVerifier_proceeds() public {
        assertEq(address(token.verifier()), address(0));

        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        assertEq(token.ownerOf(0), alice);
    }

    // ──────────────────────── Scenario 8: Verifier rejects unapproved ───

    function test_mint_verifierRejectsUnapproved() public {
        vm.prank(admin);
        token.setVerifier(address(verifier));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BVSToken.VerifierRejected.selector, alice));
        token.mint(alice, CREDENTIAL);
    }

    function test_mint_verifierApprovesWhitelisted() public {
        verifier.setApproved(alice, true);

        vm.prank(admin);
        token.setVerifier(address(verifier));

        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        assertEq(token.ownerOf(0), alice);
    }

    function test_setVerifier_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit VerifierSet(address(verifier));
        token.setVerifier(address(verifier));
    }

    function test_setVerifier_removedWithZeroAddress() public {
        vm.startPrank(admin);
        token.setVerifier(address(verifier));
        token.setVerifier(address(0));
        vm.stopPrank();

        assertEq(address(token.verifier()), address(0));

        vm.prank(admin);
        token.mint(alice, CREDENTIAL);
        assertEq(token.ownerOf(0), alice);
    }

    // ──────────────────────── Scenario 9: Non-admin mint reverts ────────

    function test_mint_byNonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(bob, CREDENTIAL);
    }

    function test_setVerifier_byNonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setVerifier(address(verifier));
    }

    // ──────────────────────── Scenario 10: Empty credential is valid ────

    function test_mint_emptyCredential() public {
        vm.prank(admin);
        token.mint(alice, EMPTY_CREDENTIAL);

        assertEq(token.ownerOf(0), alice);
        assertEq(token.getCredential(0), EMPTY_CREDENTIAL);
    }

    // ──────────────────────── Single Token Per Address ─────────────────

    function test_singleToken_revertOnDoubleMint() public {
        vm.startPrank(admin);
        token.mint(alice, CREDENTIAL);

        vm.expectRevert(abi.encodeWithSelector(BVSToken.AlreadyMember.selector, alice));
        token.mint(alice, CREDENTIAL);
        vm.stopPrank();
    }

    function test_singleToken_allowsRemintAfterBurn() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        token.burn(0);

        vm.prank(admin);
        token.mint(alice, CREDENTIAL);
        assertEq(token.ownerOf(1), alice);
    }

    function test_singleToken_disabledAllowsMultiple() public {
        BVSToken multiToken = new BVSToken(admin, false, true);

        vm.startPrank(admin);
        multiToken.mint(alice, CREDENTIAL);
        multiToken.mint(alice, CREDENTIAL);
        vm.stopPrank();

        assertEq(multiToken.balanceOf(alice), 2);
    }

    function test_singleToken_immutableFlag() public view {
        assertTrue(token.singleTokenPerAddress());
    }

    // ──────────────────────── ERC-165 Interface Support ─────────────────

    function test_supportsInterface_ERC721() public view {
        assertTrue(token.supportsInterface(0x80ac58cd)); // ERC-721
    }

    function test_supportsInterface_ERC5192() public view {
        assertTrue(token.supportsInterface(0xb45a3c0e)); // ERC-5192
    }

    function test_supportsInterface_ERC165() public view {
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC-165
    }

    // ──────────────────────── Sequential Token IDs ──────────────────────

    function test_tokenIds_autoIncrement() public {
        vm.startPrank(admin);
        token.mint(alice, CREDENTIAL);
        token.mint(bob, CREDENTIAL);
        vm.stopPrank();

        assertEq(token.ownerOf(0), alice);
        assertEq(token.ownerOf(1), bob);
    }

    // ──────────────────────── Gas Estimation ────────────────────────────

    function test_gas_mint() public {
        vm.prank(admin);
        uint256 gasBefore = gasleft();
        token.mint(alice, CREDENTIAL);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used for mint", gasUsed);
    }

    function test_gas_burn() public {
        vm.prank(admin);
        token.mint(alice, CREDENTIAL);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        token.burn(0);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used for burn", gasUsed);
    }

    // ──────────────────────── Fuzz Tests ────────────────────────────────

    function testFuzz_mint_arbitraryCredential(bytes calldata cred) public {
        vm.prank(admin);
        token.mint(alice, cred);

        assertEq(token.getCredential(0), cred);
    }

    function testFuzz_mint_multipleRecipients(address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0);

        vm.prank(admin);
        token.mint(recipient, CREDENTIAL);

        assertEq(token.ownerOf(0), recipient);
        assertTrue(token.locked(0));
    }
}
