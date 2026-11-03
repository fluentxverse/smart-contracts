// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LessonDisputes} from "../src/LessonDisputes.sol";

contract LessonDisputesLifecycleTest is Test {
    LessonDisputes internal disputes;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant ENGINE = address(0xB0B);
    address internal constant RECONCILER = address(0xCAFE);
    bytes32 internal constant KEY = keccak256("opaque lesson key");
    bytes32 internal constant POLICY = keccak256("screened policy v1");
    bytes32 internal constant EVIDENCE = keccak256("salted evidence fixture");
    bytes32 internal constant REPLY = keccak256("salted reply fixture");

    function setUp() public {
        vm.warp(2 days);
        disputes = new LessonDisputes(ADMIN, ENGINE);
        vm.startPrank(ADMIN);
        disputes.setPolicyStatus(POLICY, true);
        disputes.setPaused(false);
        vm.stopPrank();
    }

    function _open() internal {
        vm.prank(ENGINE);
        disputes.openCase(KEY, EVIDENCE, POLICY);
    }

    function _request() internal {
        _open();
        vm.prank(ENGINE);
        disputes.requestExplanation(KEY, 1 days, 2 days);
    }

    function _enableTimeouts() internal {
        vm.prank(ADMIN);
        disputes.proposeReconciler(RECONCILER);
        vm.prank(RECONCILER);
        disputes.acceptReconciler();
        vm.prank(ADMIN);
        disputes.setNonResponseEnabled(true);
    }

    function _attest() internal {
        LessonDisputes.DisputeCase memory c = disputes.getCase(KEY);
        vm.prank(RECONCILER);
        disputes.attestNoResponse(KEY, c.revision, uint64(vm.getBlockTimestamp()), EVIDENCE);
    }

    function _timedOut() internal {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        vm.prank(ENGINE);
        disputes.finalizeNonResponse(KEY);
    }

    function testTimeoutsStartDisabled() public {
        _request();
        vm.warp(3 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.NonResponseDisabled.selector);
        disputes.finalizeNonResponse(KEY);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.NonResponseDisabled.selector);
        disputes.setNonResponseEnabled(true);
    }

    function testNonResponseRequiresReconcilerAndEngine() public {
        _timedOut();
        LessonDisputes.DisputeCase memory c = disputes.getCase(KEY);
        assertTrue(c.nonResponse);
        assertFalse(c.nonResponseExcused);
        assertTrue(c.refundApproved);
        assertEq(uint256(c.cause), uint256(LessonDisputes.ResolutionCause.NonResponse));
        assertEq(c.reconciliationCommitment, EVIDENCE);
        assertEq(c.decisionCount, 1);
        assertEq(c.resolvedAt, 3 days);
        assertFalse(disputes.isTutorPayable(KEY));
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.finalizeNonResponse(KEY);
    }

    function testEngineCannotSelfAttestTimeout() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.attestNoResponse(KEY, revision, 3 days, EVIDENCE);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.finalizeNonResponse(KEY);
    }

    function testReconcilerCannotFinalizeTimeout() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        vm.prank(RECONCILER);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.finalizeNonResponse(KEY);
    }

    function testCannotAttestBeforeDeadlineOrWithBadCheckpoint() public {
        _request();
        _enableTimeouts();
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(RECONCILER);
        vm.expectRevert(LessonDisputes.DeadlineNotReached.selector);
        disputes.attestNoResponse(KEY, revision, 2 days, EVIDENCE);
        vm.warp(3 days);
        vm.startPrank(RECONCILER);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.attestNoResponse(KEY, revision, 3 days - 1, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.attestNoResponse(KEY, revision, 3 days + 1, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.attestNoResponse(KEY, revision, 3 days, bytes32(0));
        vm.expectRevert(LessonDisputes.StaleRevision.selector);
        disputes.attestNoResponse(KEY, revision - 1, 3 days, EVIDENCE);
        vm.stopPrank();
    }

    function testTimelyReplyInvalidatesPreparedTimeout() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 3 days - 1, false);
        assertEq(disputes.getNoResponseAttestation(KEY).commitment, bytes32(0));
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.finalizeNonResponse(KEY);
        assertFalse(disputes.getCase(KEY).nonResponse);
    }

    function testExtensionInvalidatesTimeoutAndKeepsOriginalDeadline() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.extendDeadline(KEY, revision, 4 days, EVIDENCE);
        assertEq(disputes.getCase(KEY).originalDeadline, 3 days);
        assertEq(disputes.getCase(KEY).responseDeadline, 4 days);
        vm.warp(4 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.finalizeNonResponse(KEY);
        _attest();
        vm.prank(ENGINE);
        disputes.finalizeNonResponse(KEY);
    }

    function testPauseAndRoleChangesInvalidateAttestations() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        vm.startPrank(ADMIN);
        disputes.setPaused(true);
        disputes.setPaused(false);
        vm.stopPrank();
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.finalizeNonResponse(KEY);
        _attest();
        vm.prank(ADMIN);
        disputes.proposeEngine(address(0xBEEF));
        vm.prank(address(0xBEEF));
        disputes.acceptEngine();
        assertFalse(disputes.nonResponseEnabled());
        vm.prank(ADMIN);
        disputes.setNonResponseEnabled(true);
        vm.prank(address(0xBEEF));
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.finalizeNonResponse(KEY);
    }

    function testHistoricalRequestDoesNotRestartClock() public {
        _open();
        vm.warp(5 days);
        vm.prank(ENGINE);
        disputes.requestExplanation(KEY, 1 days, 2 days);
        assertEq(disputes.getCase(KEY).responseDeadline, 3 days);
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 3 days - 1, false);
        assertEq(disputes.getCase(KEY).respondedAt, 3 days - 1);
    }

    function testRequestTimestampOverflowIsRejected() public {
        _open();
        vm.warp(type(uint64).max);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
        disputes.requestExplanation(KEY, 1 days, type(uint64).max);
    }

    function testBehaviorNeedsStaffApprovalAndCannotAutoRoute() public {
        vm.prank(ENGINE);
        disputes.openStaffReviewCase(KEY, EVIDENCE, POLICY);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.StaffApprovalRequired.selector);
        disputes.requestExplanation(KEY, 1 days, 2 days);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.authorizeExplanation(KEY, revision, EVIDENCE);
        vm.prank(ENGINE);
        disputes.requestExplanation(KEY, 1 days, 2 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidDecision.selector);
        disputes.recordResponse(KEY, REPLY, 2 days, true);
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 2 days, false);
        vm.prank(ADMIN);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, true, EVIDENCE);
        assertTrue(disputes.isTutorPayable(KEY));
    }

    function testStaffCanResolveBehaviorWithoutTutorRequest() public {
        vm.prank(ENGINE);
        disputes.openStaffReviewCase(KEY, EVIDENCE, POLICY);
        vm.prank(ADMIN);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.Past, false, EVIDENCE);
        assertEq(disputes.getCase(KEY).responseDeadline, 0);
        assertFalse(disputes.isTutorPayable(KEY));
    }

    function testPolicyApprovalAndRevocation() public {
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.PolicyNotApproved.selector);
        disputes.openCase(KEY, EVIDENCE, REPLY);
        _open();
        vm.prank(ADMIN);
        disputes.setPolicyStatus(POLICY, false);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.PolicyNotApproved.selector);
        disputes.openCase(REPLY, EVIDENCE, POLICY);
        vm.prank(ADMIN);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE);
        assertEq(disputes.getCase(KEY).policyHash, POLICY);
    }

    function testNoShowWithoutReportAndExactlyOneRefundReceipt() public {
        vm.prank(ENGINE);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days, 2 days);
        assertFalse(disputes.getCase(KEY).nonResponse);
        assertEq(uint256(disputes.getCase(KEY).cause), uint256(LessonDisputes.ResolutionCause.NoShow));
        bytes32 instruction = disputes.refundInstructionId(KEY);
        vm.prank(ENGINE);
        disputes.recordRefundDelivery(KEY, REPLY);
        assertEq(disputes.refundInstructionId(KEY), instruction);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.RefundAlreadyRecorded.selector);
        disputes.recordRefundDelivery(KEY, EVIDENCE);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days, 2 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.CaseAlreadyExists.selector);
        disputes.openCase(KEY, EVIDENCE, POLICY);
    }

    function testNoShowClosesReplyObligationWithoutNonResponse() public {
        _request();
        vm.prank(ENGINE);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days, 2 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.recordResponse(KEY, REPLY, 2 days, false);
        assertFalse(disputes.getCase(KEY).nonResponse);
    }

    function testNoShowRejectsIncompleteOrContradictoryTiming() public {
        _request();
        vm.startPrank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days, 1 days - 1);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days, 2 days + 1);
        vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
        disputes.resolveNoShow(KEY, EVIDENCE, POLICY, 1 days + 1, 2 days);
        vm.stopPrank();
    }

    function testReconsiderationPreservesHistoryAndRefund() public {
        _timedOut();
        bytes32 instruction = disputes.refundInstructionId(KEY);
        LessonDisputes.Decision memory first = disputes.getDecision(KEY, 1);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.reconsider(KEY, revision, LessonDisputes.Outcome.NoPenalty, true, true, REPLY);
        LessonDisputes.DisputeCase memory c = disputes.getCase(KEY);
        assertEq(c.decisionCount, 2);
        assertTrue(c.nonResponse);
        assertTrue(c.nonResponseExcused);
        assertTrue(c.refundApproved);
        assertTrue(disputes.isTutorPayable(KEY));
        assertEq(disputes.refundInstructionId(KEY), instruction);
        assertEq(disputes.getDecision(KEY, 1).commitment, first.commitment);
        assertEq(uint256(disputes.getDecision(KEY, 1).outcome), uint256(LessonDisputes.Outcome.TA301));
        assertEq(disputes.getDecision(KEY, 2).actor, ADMIN);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.StaleRevision.selector);
        disputes.reconsider(KEY, revision, LessonDisputes.Outcome.Past, true, false, REPLY);
        vm.prank(ADMIN);
        disputes.reconsider(KEY, c.revision, LessonDisputes.Outcome.TA301, true, false, EVIDENCE);
        assertTrue(disputes.getCase(KEY).nonResponseExcused);
    }

    function testApprovedRefundCannotBeWithdrawnDuringAppeal() public {
        _open();
        vm.prank(ADMIN);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, true, EVIDENCE);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidDecision.selector);
        disputes.reconsider(KEY, revision, LessonDisputes.Outcome.NoPenalty, false, false, REPLY);
    }

    function testRefundDeliveryAllowedWhilePausedAndNeverReissued() public {
        _timedOut();
        vm.prank(ADMIN);
        disputes.setPaused(true);
        vm.prank(ENGINE);
        disputes.recordRefundDelivery(KEY, REPLY);
        vm.prank(ADMIN);
        disputes.setPaused(false);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.reconsider(KEY, revision, LessonDisputes.Outcome.NoPenalty, true, false, EVIDENCE);
        assertEq(disputes.getCase(KEY).refundReceiptCommitment, REPLY);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.RefundAlreadyRecorded.selector);
        disputes.recordRefundDelivery(KEY, REPLY);
    }

    function testRefundDeliveryRequiresApprovalAndCommitment() public {
        _open();
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.RefundNotApproved.selector);
        disputes.recordRefundDelivery(KEY, REPLY);
        vm.prank(ADMIN);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, true, EVIDENCE);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.recordRefundDelivery(KEY, bytes32(0));
    }

    function testStaffOverrideWinsAgainstAutomaticPenalty() public {
        _request();
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 2 days, true);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.overrideActiveCase(KEY, revision, LessonDisputes.Outcome.NoPenalty, true, EVIDENCE);
        vm.warp(3 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.finalizeAcknowledgedTA301(KEY);
        assertTrue(disputes.isTutorPayable(KEY));
    }

    function testExtensionDuringOutageAndStaleRevision() public {
        _request();
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.setPaused(true);
        vm.prank(ADMIN);
        disputes.extendDeadline(KEY, revision, 4 days, EVIDENCE);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.StaleRevision.selector);
        disputes.extendDeadline(KEY, revision, 5 days, EVIDENCE);
        vm.warp(3 days + 1);
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 3 days, false);
        assertEq(disputes.getCase(KEY).respondedAt, 3 days);
    }

    function testExtensionDelaysAcknowledgedPenalty() public {
        _request();
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 2 days, true);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(ADMIN);
        disputes.extendDeadline(KEY, revision, 4 days, EVIDENCE);
        vm.warp(3 days);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.DeadlineNotReached.selector);
        disputes.finalizeAcknowledgedTA301(KEY);
        vm.warp(4 days);
        vm.prank(ENGINE);
        disputes.finalizeAcknowledgedTA301(KEY);
    }

    function testOwnershipTransferRequiresAcceptance() public {
        address next = address(0xD00D);
        vm.prank(ADMIN);
        disputes.transferOwnership(next);
        assertEq(disputes.administrator(), ADMIN);
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        disputes.acceptOwnership();
        vm.prank(next);
        disputes.acceptOwnership();
        assertEq(disputes.administrator(), next);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.setPaused(true);
    }

    function testRoleSeparationAndNoRenunciation() public {
        LessonDisputes shared = new LessonDisputes(ADMIN, ADMIN);
        assertEq(shared.administrator(), shared.engine());
        vm.startPrank(ADMIN);
        disputes.proposeEngine(ADMIN);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeReconciler(ENGINE);
        disputes.transferOwnership(ENGINE);
        vm.expectRevert(LessonDisputes.RenunciationDisabled.selector);
        disputes.renounceOwnership();
        vm.stopPrank();
    }

    function testEngineRotationRevokesPreviousKey() public {
        address next = address(0xBEEF);
        vm.prank(ADMIN);
        disputes.proposeEngine(next);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.acceptEngine();
        vm.prank(next);
        disputes.acceptEngine();
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.openCase(KEY, EVIDENCE, POLICY);
        vm.prank(next);
        disputes.openCase(KEY, EVIDENCE, POLICY);
    }

    function testMissingCaseAndDecisionGuards() public {
        vm.expectRevert(LessonDisputes.CaseNotFound.selector);
        disputes.isTutorPayable(KEY);
        vm.expectRevert(LessonDisputes.CaseNotFound.selector);
        disputes.refundInstructionId(KEY);
        _open();
        vm.expectRevert(LessonDisputes.DecisionNotFound.selector);
        disputes.getDecision(KEY, 0);
        vm.expectRevert(LessonDisputes.DecisionNotFound.selector);
        disputes.getDecision(KEY, 1);
    }

    function testResponseRejectsZeroPreRequestAndFutureEvidence() public {
        _request();
        vm.startPrank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.recordResponse(KEY, bytes32(0), 2 days, false);
        vm.expectRevert(LessonDisputes.InvalidResponseTime.selector);
        disputes.recordResponse(KEY, REPLY, 2 days - 1, false);
        vm.expectRevert(LessonDisputes.InvalidResponseTime.selector);
        disputes.recordResponse(KEY, REPLY, 2 days + 1, false);
        vm.stopPrank();
    }

    function testFuzzTimelyReplySurvivesArbitrarySubmissionDelay(uint32 delay, bool automatic) public {
        _request();
        uint256 submittedAt = 3 days + uint256(delay);
        vm.warp(submittedAt);
        vm.prank(ENGINE);
        disputes.recordResponse(KEY, REPLY, 3 days - 1, automatic);
        assertEq(disputes.getCase(KEY).respondedAt, 3 days - 1);
        assertFalse(disputes.getCase(KEY).nonResponse);
    }

    function testFuzzUnprivilegedCallerCannotMutate(address caller) public {
        vm.assume(caller != ADMIN && caller != ENGINE && caller != RECONCILER);
        _request();
        vm.startPrank(caller);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.recordResponse(KEY, REPLY, 2 days, false);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.recordRefundDelivery(KEY, REPLY);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.overrideActiveCase(KEY, 2, LessonDisputes.Outcome.TA301, true, EVIDENCE);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.setPolicyStatus(POLICY, false);
        vm.stopPrank();
    }

    function testFuzzAllOperationalEndpointsRejectStrangers(address caller) public {
        vm.assume(caller != ADMIN && caller != ENGINE && caller != RECONCILER);
        bytes[] memory calls = new bytes[](17);
        calls[0] = abi.encodeCall(disputes.proposeEngine, (address(0xBEEF)));
        calls[1] = abi.encodeCall(disputes.proposeReconciler, (RECONCILER));
        calls[2] = abi.encodeCall(disputes.acceptEngine, ());
        calls[3] = abi.encodeCall(disputes.acceptReconciler, ());
        calls[4] = abi.encodeCall(disputes.setPaused, (true));
        calls[5] = abi.encodeCall(disputes.setNonResponseEnabled, (true));
        calls[6] = abi.encodeCall(disputes.openCase, (KEY, EVIDENCE, POLICY));
        calls[7] = abi.encodeCall(disputes.openStaffReviewCase, (KEY, EVIDENCE, POLICY));
        calls[8] = abi.encodeCall(disputes.authorizeExplanation, (KEY, 1, EVIDENCE));
        calls[9] = abi.encodeCall(disputes.requestExplanation, (KEY, 1 days, 2 days));
        calls[10] = abi.encodeCall(disputes.extendDeadline, (KEY, 1, 4 days, EVIDENCE));
        calls[11] = abi.encodeCall(disputes.attestNoResponse, (KEY, 1, 3 days, EVIDENCE));
        calls[12] = abi.encodeCall(disputes.finalizeNonResponse, (KEY));
        calls[13] = abi.encodeCall(disputes.finalizeAcknowledgedTA301, (KEY));
        calls[14] = abi.encodeCall(disputes.resolveByStaff, (KEY, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE));
        calls[15] = abi.encodeCall(disputes.resolveNoShow, (KEY, EVIDENCE, POLICY, 1 days, 2 days));
        calls[16] =
            abi.encodeCall(disputes.reconsider, (KEY, 1, LessonDisputes.Outcome.NoPenalty, true, false, EVIDENCE));
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool success, bytes memory result) = address(disputes).call(calls[i]);
            assertFalse(success);
            assertEq(result, abi.encodeWithSelector(LessonDisputes.Unauthorized.selector));
        }
    }

    function testApprovalGuards() public {
        _open();
        vm.startPrank(ADMIN);
        vm.expectRevert(LessonDisputes.StaleRevision.selector);
        disputes.authorizeExplanation(KEY, 0, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.authorizeExplanation(KEY, 1, bytes32(0));
        disputes.authorizeExplanation(KEY, 1, EVIDENCE);
        vm.expectRevert(LessonDisputes.ExplanationAlreadyRequested.selector);
        disputes.authorizeExplanation(KEY, 2, EVIDENCE);
        vm.stopPrank();
        vm.prank(ENGINE);
        disputes.requestExplanation(KEY, 1 days, 2 days);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.authorizeExplanation(KEY, 3, EVIDENCE);
    }

    function testExtensionGuards() public {
        _request();
        uint64 revision = disputes.getCase(KEY).revision;
        vm.startPrank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.extendDeadline(KEY, revision, 4 days, bytes32(0));
        vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
        disputes.extendDeadline(KEY, revision, 3 days, EVIDENCE);
        vm.warp(5 days);
        vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
        disputes.extendDeadline(KEY, revision, 4 days, EVIDENCE);
        disputes.overrideActiveCase(KEY, revision, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.extendDeadline(KEY, revision + 1, 6 days, EVIDENCE);
        vm.stopPrank();
    }

    function testOverrideAndReconsiderGuards() public {
        _open();
        vm.startPrank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.reconsider(KEY, 1, LessonDisputes.Outcome.NoPenalty, false, false, EVIDENCE);
        vm.expectRevert(LessonDisputes.StaleRevision.selector);
        disputes.overrideActiveCase(KEY, 0, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.Past, false, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.overrideActiveCase(KEY, 2, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE);
        vm.expectRevert(LessonDisputes.InvalidDecision.selector);
        disputes.reconsider(KEY, 2, LessonDisputes.Outcome.NoPenalty, false, true, EVIDENCE);
        vm.stopPrank();
    }

    function testMissingCommitmentsAndNoShowPolicyMismatch() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.setPolicyStatus(bytes32(0), true);
        vm.stopPrank();
        _open();
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, false, bytes32(0));
        vm.startPrank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.resolveNoShow(KEY, bytes32(0), POLICY, 1 days, 2 days);
        vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
        disputes.resolveNoShow(KEY, EVIDENCE, REPLY, 1 days, 2 days);
        vm.stopPrank();
    }

    function testPauseBlocksTimeoutsAndReconfigurationDisablesOldAttestations() public {
        _request();
        _enableTimeouts();
        vm.warp(3 days);
        _attest();
        vm.prank(ADMIN);
        disputes.setPaused(true);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.ContractPaused.selector);
        disputes.finalizeNonResponse(KEY);
        vm.prank(ADMIN);
        disputes.setPaused(false);
        _attest();
        vm.prank(ADMIN);
        disputes.setNonResponseEnabled(false);
        uint64 revision = disputes.getCase(KEY).revision;
        vm.prank(RECONCILER);
        vm.expectRevert(LessonDisputes.NonResponseDisabled.selector);
        disputes.attestNoResponse(KEY, revision, 3 days, EVIDENCE);
        vm.prank(ADMIN);
        disputes.setNonResponseEnabled(true);
        vm.prank(ENGINE);
        vm.expectRevert(LessonDisputes.InvalidReconciliation.selector);
        disputes.finalizeNonResponse(KEY);
    }

    function testPendingRolesCannotOverlapAndProposalsCanBeReplaced() public {
        address candidate = address(0xD00D);
        vm.startPrank(ADMIN);
        vm.expectRevert(LessonDisputes.ZeroAddress.selector);
        disputes.proposeEngine(address(0));
        vm.expectRevert(LessonDisputes.ZeroAddress.selector);
        disputes.proposeReconciler(address(0));
        disputes.proposeEngine(candidate);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeReconciler(candidate);
        disputes.transferOwnership(candidate);
        disputes.proposeEngine(address(0xBEEF));
        disputes.transferOwnership(candidate);
        disputes.proposeEngine(candidate);
        vm.expectRevert(LessonDisputes.RoleOverlap.selector);
        disputes.proposeReconciler(candidate);
        disputes.transferOwnership(address(0));
        assertEq(disputes.pendingOwner(), address(0));
        vm.stopPrank();
    }

    function testReconcilerAndOwnerChangesDisableTimeouts() public {
        _enableTimeouts();
        vm.prank(ADMIN);
        disputes.proposeReconciler(address(0xD00D));
        vm.prank(RECONCILER);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.acceptReconciler();
        vm.prank(address(0xD00D));
        disputes.acceptReconciler();
        assertFalse(disputes.nonResponseEnabled());
        vm.startPrank(ADMIN);
        disputes.setNonResponseEnabled(true);
        disputes.transferOwnership(address(0xBEEF));
        vm.stopPrank();
        vm.prank(address(0xBEEF));
        disputes.acceptOwnership();
        assertFalse(disputes.nonResponseEnabled());
    }

    function testNoPayableEntrypoint() public {
        vm.deal(ENGINE, 1 ether);
        vm.prank(ENGINE);
        (bool success,) = address(disputes).call{value: 1 wei}("");
        assertFalse(success);
        assertEq(address(disputes).balance, 0);
    }

    function testResolutionTimestampOverflowCannotTruncateAuditTime() public {
        _open();
        vm.warp(uint256(type(uint64).max) + 1);
        vm.prank(ADMIN);
        vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
        disputes.resolveByStaff(KEY, LessonDisputes.Outcome.NoPenalty, false, EVIDENCE);
        assertEq(uint256(disputes.getCase(KEY).stage), uint256(LessonDisputes.CaseStage.AwaitingStaff));
    }
}
