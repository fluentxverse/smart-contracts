// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LessonDisputes} from "../src/LessonDisputes.sol";

contract LessonDisputesTest is Test {
    address internal administrator = address(0xA11CE);
    address internal engine = address(0xB0B);

    function testConstructorSetsConfiguration() public {
        LessonDisputes disputes = new LessonDisputes(administrator, engine);

        assertEq(disputes.administrator(), administrator);
        assertEq(disputes.engine(), engine);
        assertTrue(disputes.paused());
    }

    function testConstructorRejectsZeroAdministrator() public {
        vm.expectRevert(LessonDisputes.ZeroAddress.selector);
        new LessonDisputes(address(0), engine);
    }

    function testConstructorRejectsZeroEngine() public {
        vm.expectRevert(LessonDisputes.ZeroAddress.selector);
        new LessonDisputes(administrator, address(0));
    }

    function testAdministratorCanUnpauseAndPause() public {
        LessonDisputes disputes = new LessonDisputes(administrator, engine);
        vm.prank(administrator);
        disputes.setPaused(false);
        assertFalse(disputes.paused());

        vm.prank(administrator);
        disputes.setPaused(true);
        assertTrue(disputes.paused());
    }

    function testEngineCannotUnpause() public {
        LessonDisputes disputes = new LessonDisputes(administrator, engine);
        vm.prank(engine);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.setPaused(false);

        assertTrue(disputes.paused());
    }

    function readyContract() internal returns (LessonDisputes disputes) {
        disputes = new LessonDisputes(administrator, engine);
        vm.prank(administrator);
        disputes.setPolicyStatus(bytes32(uint256(3)), true);
        vm.prank(administrator);
        disputes.setPaused(false);
    }

    function testEngineOpenCase() public {
        LessonDisputes disputes = readyContract();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 complaint = bytes32(uint256(2));
        bytes32 policy = bytes32(uint256(3));

        vm.prank(engine);
        disputes.openCase(lesson, complaint, policy);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(record.complaintCommitment, complaint);
        assertEq(record.policyHash, policy);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.AwaitingStaff));
        assertEq(record.responseDeadline, 0);
        assertFalse(record.refundApproved);
    }

    function testCannotReadMissingCase() public {
        LessonDisputes disputes = readyContract();

        vm.expectRevert(LessonDisputes.CaseNotFound.selector);
        disputes.getCase(bytes32(uint256(1)));
    }

    function testNonEngineCannotOpenCase() public {
        LessonDisputes disputes = readyContract();

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.openCase(bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)));
    }

    function testCannotOpenCaseWhilePaused() public {
        LessonDisputes disputes = new LessonDisputes(administrator, engine);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.ContractPaused.selector);
        disputes.openCase(bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)));
    }

    function testCannotOpenDuplicateCase() public {
        LessonDisputes disputes = readyContract();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 complaint = bytes32(uint256(2));
        bytes32 policy = bytes32(uint256(3));

        vm.prank(engine);
        disputes.openCase(lesson, complaint, policy);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.CaseAlreadyExists.selector);
        disputes.openCase(lesson, bytes32(uint256(99)), policy);

        assertEq(disputes.getCase(lesson).complaintCommitment, complaint);
    }

    function testCannotOpenCaseWithZeroInputs() public {
        LessonDisputes disputes = readyContract();

        for (uint256 i = 0; i < 3; i++) {
            bytes32[3] memory inputs = [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))];
            inputs[i] = bytes32(0);

            vm.prank(engine);
            vm.expectRevert(LessonDisputes.InvalidCommitment.selector);
            disputes.openCase(inputs[0], inputs[1], inputs[2]);
        }
    }

    function explanationCase() internal returns (LessonDisputes disputes) {
        disputes = readyContract();

        vm.prank(engine);
        disputes.openCase(bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)));
    }

    function testDeadlineUsesInboxCreationTime() public {
        vm.warp(2 days);
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));
        uint64 createdAt = uint64(block.timestamp - 60);

        vm.prank(engine);
        disputes.requestExplanation(lesson, uint64(1 days), createdAt);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);

        assertEq(record.responseDeadline, uint256(createdAt) + 24 hours);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.AwaitingTutor));
        assertEq(record.respondedAt, 0);
    }

    function testRepeatedRequestCannotResetDeadline() public {
        vm.warp(2 days);
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));
        uint64 createdAt = uint64(block.timestamp);

        vm.prank(engine);
        disputes.requestExplanation(lesson, uint64(1 days), createdAt);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.ExplanationAlreadyRequested.selector);
        disputes.requestExplanation(lesson, uint64(1 days), uint64(block.timestamp));

        assertEq(disputes.getCase(lesson).responseDeadline, uint256(createdAt) + 24 hours);
    }

    function testExplanationRejectsInvalidTimes() public {
        vm.warp(2 days);
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));

        uint64[3] memory invalidTimes = [uint64(1 days - 1), uint64(2 days + 1), uint64(0)];

        for (uint256 i = 0; i < invalidTimes.length; i++) {
            vm.prank(engine);
            vm.expectRevert(LessonDisputes.InvalidRequestTime.selector);
            disputes.requestExplanation(lesson, uint64(1 days), invalidTimes[i]);
        }

        assertEq(disputes.getCase(lesson).responseDeadline, 0);
    }

    function testAdministratorCannotRequestExplanation() public {
        vm.warp(2 days);
        LessonDisputes disputes = explanationCase();

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.requestExplanation(bytes32(uint256(1)), uint64(1 days), uint64(2 days));
    }

    function testCannotRequestExplanationWhilePaused() public {
        vm.warp(2 days);
        LessonDisputes disputes = explanationCase();

        vm.prank(administrator);
        disputes.setPaused(true);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.ContractPaused.selector);
        disputes.requestExplanation(bytes32(uint256(1)), uint64(1 days), uint64(2 days));
    }

    function responseCase() internal returns (LessonDisputes disputes) {
        vm.warp(2 days);
        disputes = explanationCase();

        vm.prank(engine);
        disputes.requestExplanation(bytes32(uint256(1)), uint64(1 days), uint64(2 days));
    }

    function testFuzzResponseRouting(bool automaticTA301) public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 reply = bytes32(uint256(4));

        vm.prank(engine);
        disputes.recordResponse(lesson, reply, uint64(block.timestamp), automaticTA301);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        LessonDisputes.CaseStage expected =
            automaticTA301 ? LessonDisputes.CaseStage.PendingTA301 : LessonDisputes.CaseStage.AwaitingStaff;

        assertEq(uint256(record.stage), uint256(expected));
        assertEq(record.responseCommitment, reply);
        assertEq(record.respondedAt, block.timestamp);
        assertEq(uint256(record.outcome), uint256(LessonDisputes.Outcome.Unresolved));
        assertFalse(record.refundApproved);
    }

    function testCannotReplyTwice() public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 reply = bytes32(uint256(4));

        vm.prank(engine);
        disputes.recordResponse(lesson, reply, uint64(block.timestamp), false);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.ResponseAlreadySubmitted.selector);
        disputes.recordResponse(lesson, reply, uint64(block.timestamp), false);
    }

    function testReplyAtDeadlineIsRejected() public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));
        uint64 deadline = disputes.getCase(lesson).responseDeadline;
        vm.warp(deadline);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.InvalidResponseTime.selector);
        disputes.recordResponse(lesson, bytes32(uint256(4)), deadline, false);
    }

    function testTimelyReplyCanBeRecordedAfterDeadline() public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));
        uint64 deadline = disputes.getCase(lesson).responseDeadline;
        uint64 receivedAt = deadline - 1;

        vm.warp(uint256(deadline) + 1 hours);

        vm.prank(engine);
        disputes.recordResponse(lesson, bytes32(uint256(4)), receivedAt, false);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(record.respondedAt, receivedAt);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.AwaitingStaff));
        assertFalse(record.nonResponse);
    }

    function testReplyCanBeRecordedWhilePaused() public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));

        vm.prank(administrator);
        disputes.setPaused(true);

        vm.prank(engine);
        disputes.recordResponse(lesson, bytes32(uint256(4)), uint64(block.timestamp), false);

        assertTrue(disputes.paused());
        assertEq(disputes.getCase(lesson).responseCommitment, bytes32(uint256(4)));
    }

    function testAdministratorCannotRecordTutorReply() public {
        LessonDisputes disputes = responseCase();

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.recordResponse(bytes32(uint256(1)), bytes32(uint256(4)), uint64(block.timestamp), false);
    }

    function pendingTA301Case() internal returns (LessonDisputes disputes) {
        disputes = responseCase();

        vm.prank(engine);
        disputes.recordResponse(bytes32(uint256(1)), bytes32(uint256(4)), uint64(block.timestamp), true);
    }

    function testCannotFinalizeTA301BeforeDeadline() public {
        LessonDisputes disputes = pendingTA301Case();
        bytes32 lesson = bytes32(uint256(1));
        vm.warp(disputes.getCase(lesson).responseDeadline - 1);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.DeadlineNotReached.selector);
        disputes.finalizeAcknowledgedTA301(lesson);
    }

    function testFinalizeTA301AtDeadline() public {
        LessonDisputes disputes = pendingTA301Case();
        bytes32 lesson = bytes32(uint256(1));
        vm.warp(disputes.getCase(lesson).responseDeadline);

        vm.prank(engine);
        disputes.finalizeAcknowledgedTA301(lesson);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.Resolved));
        assertEq(uint256(record.outcome), uint256(LessonDisputes.Outcome.TA301));
        assertTrue(record.refundApproved);
        assertFalse(record.nonResponse);
    }

    function testCannotFinalizeTA301Twice() public {
        LessonDisputes disputes = pendingTA301Case();
        bytes32 lesson = bytes32(uint256(1));
        vm.warp(disputes.getCase(lesson).responseDeadline);

        vm.prank(engine);
        disputes.finalizeAcknowledgedTA301(lesson);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.finalizeAcknowledgedTA301(lesson);
    }

    function testStaffReviewCaseCannotAutoFinalize() public {
        LessonDisputes disputes = responseCase();
        bytes32 lesson = bytes32(uint256(1));

        vm.prank(engine);
        disputes.recordResponse(lesson, bytes32(uint256(4)), uint64(block.timestamp), false);

        vm.warp(disputes.getCase(lesson).responseDeadline);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.finalizeAcknowledgedTA301(lesson);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.AwaitingStaff));
        assertFalse(record.refundApproved);
    }

    function testAdministratorCannotAutoFinalizeTA301() public {
        LessonDisputes disputes = pendingTA301Case();
        bytes32 lesson = bytes32(uint256(1));
        vm.warp(disputes.getCase(lesson).responseDeadline);

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.finalizeAcknowledgedTA301(lesson);
    }

    function testCannotAutoFinalizeTA301WhilePaused() public {
        LessonDisputes disputes = pendingTA301Case();
        bytes32 lesson = bytes32(uint256(1));
        vm.warp(disputes.getCase(lesson).responseDeadline);

        vm.prank(administrator);
        disputes.setPaused(true);

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.ContractPaused.selector);
        disputes.finalizeAcknowledgedTA301(lesson);

        assertEq(uint256(disputes.getCase(lesson).stage), uint256(LessonDisputes.CaseStage.PendingTA301));
    }

    function testFuzzStaffOutcomes(uint8 outcomeCode, bool refund) public {
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 decision = bytes32(uint256(5));

        LessonDisputes.Outcome outcome = LessonDisputes.Outcome(uint8(bound(outcomeCode, 1, 3)));
        bool approvedRefund = outcome == LessonDisputes.Outcome.TA301 || refund;

        vm.prank(administrator);
        disputes.resolveByStaff(lesson, outcome, approvedRefund, decision);

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(uint256(record.stage), uint256(LessonDisputes.CaseStage.Resolved));
        assertEq(uint256(record.outcome), uint256(outcome));
        assertEq(record.refundApproved, approvedRefund);
        assertEq(record.decisionCommitment, decision);
        assertFalse(record.nonResponse);
    }

    function testStaffCannotMakeInvalidDecision() public {
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 decision = bytes32(uint256(5));

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.InvalidDecision.selector);
        disputes.resolveByStaff(lesson, LessonDisputes.Outcome.Unresolved, false, decision);

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.InvalidDecision.selector);
        disputes.resolveByStaff(lesson, LessonDisputes.Outcome.TA301, false, decision);

        assertEq(uint256(disputes.getCase(lesson).stage), uint256(LessonDisputes.CaseStage.AwaitingStaff));
    }

    function testEngineCannotResolveStaffCase() public {
        LessonDisputes disputes = explanationCase();

        vm.prank(engine);
        vm.expectRevert(LessonDisputes.Unauthorized.selector);
        disputes.resolveByStaff(bytes32(uint256(1)), LessonDisputes.Outcome.NoPenalty, false, bytes32(uint256(5)));
    }

    function testCannotResolveStaffCaseWhilePaused() public {
        LessonDisputes disputes = explanationCase();

        vm.prank(administrator);
        disputes.setPaused(true);

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.ContractPaused.selector);
        disputes.resolveByStaff(bytes32(uint256(1)), LessonDisputes.Outcome.NoPenalty, false, bytes32(uint256(5)));
    }

    function testStaffCannotOverwriteResolvedCase() public {
        LessonDisputes disputes = explanationCase();
        bytes32 lesson = bytes32(uint256(1));
        bytes32 decision = bytes32(uint256(5));

        vm.prank(administrator);
        disputes.resolveByStaff(lesson, LessonDisputes.Outcome.NoPenalty, true, decision);

        vm.prank(administrator);
        vm.expectRevert(LessonDisputes.InvalidCaseStage.selector);
        disputes.resolveByStaff(lesson, LessonDisputes.Outcome.TA301, true, bytes32(uint256(6)));

        LessonDisputes.DisputeCase memory record = disputes.getCase(lesson);
        assertEq(uint256(record.outcome), uint256(LessonDisputes.Outcome.NoPenalty));
        assertEq(record.decisionCommitment, decision);
        assertTrue(record.refundApproved);
    }
}
