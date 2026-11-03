// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LessonDisputes} from "../src/LessonDisputes.sol";

contract LessonDisputesRolesTest is Test {
    address internal constant SHARED = address(0xA11CE);
    address internal constant NEXT = address(0xB0B);
    address internal constant RECONCILER = address(0xCAFE);
    bytes32 internal constant POLICY = keccak256("policy");
    bytes32 internal constant EVIDENCE = keccak256("evidence");
    bytes32 internal constant KEY = keccak256("lesson");
    LessonDisputes internal disputes;

    function setUp() public {
        vm.warp(2 days);
        disputes = new LessonDisputes(SHARED, SHARED);
    }

    function testFuzzSharedWalletCanPerformBothRoles(address actor) public {
        vm.assume(actor != address(0));
        LessonDisputes shared = new LessonDisputes(actor, actor);
        assertTrue(shared.paused());
        assertFalse(shared.nonResponseEnabled());
        assertEq(shared.reconciler(), address(0));
        vm.startPrank(actor);
        shared.setPolicyStatus(POLICY, true);
        shared.setPaused(false);
        shared.openCase(KEY, EVIDENCE, POLICY);
        shared.resolveByStaff(KEY, LessonDisputes.Outcome.TA301, true, EVIDENCE);
        shared.recordRefundDelivery(KEY, EVIDENCE);
        vm.stopPrank();
        assertTrue(shared.getCase(KEY).refundApproved);
        assertFalse(shared.isTutorPayable(KEY));
    }

    function testSharedRolesStillRejectOutsiders() public {
        vm.prank(SHARED);
        disputes.setPaused(false);
        vm.startPrank(NEXT);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.setPolicyStatus(POLICY, true);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.openCase(KEY, EVIDENCE, POLICY);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.attestNoResponse(KEY, 1, uint64(block.timestamp), EVIDENCE);
        vm.stopPrank();
    }

    function testSharedWalletCannotReconcileItselfOrEnableWithoutReconciler() public {
        vm.startPrank(SHARED);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeReconciler(SHARED);
        vm.expectRevert(LessonDisputes.NonResponseDisabled.selector);
        disputes.setNonResponseEnabled(true);
        disputes.proposeReconciler(RECONCILER);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.acceptReconciler();
        vm.stopPrank();
    }

    function _enableTimeouts() internal {
        vm.prank(SHARED);
        disputes.proposeReconciler(RECONCILER);
        vm.prank(RECONCILER);
        disputes.acceptReconciler();
        vm.prank(SHARED);
        disputes.setNonResponseEnabled(true);
    }

    function testCanSeparateAdministratorLater() public {
        _enableTimeouts();
        uint64 epoch = disputes.configurationEpoch();
        vm.prank(SHARED);
        disputes.transferOwnership(NEXT);
        assertEq(disputes.administrator(), SHARED);
        vm.prank(NEXT);
        disputes.acceptOwnership();
        assertEq(disputes.administrator(), NEXT);
        assertEq(disputes.engine(), SHARED);
        assertFalse(disputes.nonResponseEnabled());
        assertGt(disputes.configurationEpoch(), epoch);
        vm.prank(SHARED);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.setPaused(false);
    }

    function testCanSeparateOperatorLater() public {
        _enableTimeouts();
        vm.prank(SHARED);
        disputes.proposeEngine(NEXT);
        assertEq(disputes.engine(), SHARED);
        vm.prank(NEXT);
        disputes.acceptEngine();
        assertEq(disputes.administrator(), SHARED);
        assertEq(disputes.engine(), NEXT);
        assertFalse(disputes.nonResponseEnabled());
    }

    function testCanMergeAdministratorIntoOperator() public {
        LessonDisputes split = new LessonDisputes(SHARED, NEXT);
        vm.prank(SHARED);
        split.transferOwnership(NEXT);
        vm.prank(NEXT);
        split.acceptOwnership();
        assertEq(split.administrator(), split.engine());
        assertFalse(split.nonResponseEnabled());
    }

    function testCanMergeOperatorIntoAdministrator() public {
        LessonDisputes split = new LessonDisputes(SHARED, NEXT);
        vm.prank(SHARED);
        split.proposeEngine(SHARED);
        vm.prank(SHARED);
        split.acceptEngine();
        assertEq(split.administrator(), split.engine());
    }

    function testReconcilerCannotBecomeAdministratorOrOperator() public {
        _enableTimeouts();
        vm.startPrank(SHARED);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.transferOwnership(RECONCILER);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeEngine(RECONCILER);
        disputes.proposeReconciler(address(0xD00D));
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.transferOwnership(address(0xD00D));
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeEngine(address(0xD00D));
        vm.stopPrank();
    }

    function testPendingCombinedRoleStillReservesReconcilerSeparation() public {
        vm.startPrank(SHARED);
        disputes.transferOwnership(NEXT);
        disputes.proposeEngine(NEXT);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeReconciler(NEXT);
        vm.stopPrank();
        vm.startPrank(NEXT);
        disputes.acceptEngine();
        disputes.acceptOwnership();
        vm.stopPrank();
        assertEq(disputes.administrator(), NEXT);
        assertEq(disputes.engine(), NEXT);
    }
}
