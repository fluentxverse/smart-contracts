// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LessonDisputes} from "../src/LessonDisputes.sol";

contract DisputeHandler is Test {
    LessonDisputes public disputes;
    address internal constant ADMIN = address(0xA11CE);
    address internal immutable ENGINE;
    address internal constant RECONCILER = address(0xCAFE);
    bytes32 internal constant EVIDENCE = keccak256("private test evidence");
    bytes32 internal constant POLICY = keccak256("policy v1");
    mapping(uint256 => bool) public opened;
    mapping(uint256 => bytes32) public firstDecisionHash;
    mapping(uint256 => bool) public refundEverApproved;
    mapping(uint256 => bytes32) public originalReply;
    mapping(uint256 => uint256) public refundDeliveryCount;

    constructor(bool sharedRoles) {
        ENGINE = sharedRoles ? ADMIN : address(0xB0B);
        vm.warp(2 days);
        disputes = new LessonDisputes(ADMIN, ENGINE);
        vm.startPrank(ADMIN);
        disputes.setPolicyStatus(POLICY, true);
        disputes.proposeReconciler(RECONCILER);
        vm.stopPrank();
        vm.prank(RECONCILER);
        disputes.acceptReconciler();
        vm.startPrank(ADMIN);
        disputes.setNonResponseEnabled(true);
        disputes.setPaused(false);
        vm.stopPrank();
    }

    function open(uint8 seed, bool behavior) external {
        uint256 i = seed % 8;
        if (opened[i]) return;
        vm.prank(ENGINE);
        if (behavior) disputes.openStaffReviewCase(_key(i), EVIDENCE, POLICY);
        else disputes.openCase(_key(i), EVIDENCE, POLICY);
        opened[i] = true;
    }

    function request(uint8 seed) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.stage != LessonDisputes.CaseStage.AwaitingStaff || c.responseDeadline != 0) return;
        if (c.kind == LessonDisputes.CaseKind.StaffFirst) {
            vm.prank(ADMIN);
            disputes.authorizeExplanation(_key(i), c.revision, EVIDENCE);
        }
        vm.prank(ENGINE);
        disputes.requestExplanation(_key(i), 1 days, uint64(vm.getBlockTimestamp()));
    }

    function reply(uint8 seed, bool automatic) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.stage != LessonDisputes.CaseStage.AwaitingTutor) return;
        vm.prank(ENGINE);
        disputes.recordResponse(
            _key(i), EVIDENCE, c.explanationRequestedAt, automatic && c.kind == LessonDisputes.CaseKind.Standard
        );
        originalReply[i] = EVIDENCE;
    }

    function advance(uint32 delta) external {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 0, 2 days));
    }

    function extend(uint8 seed) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.stage != LessonDisputes.CaseStage.AwaitingTutor && c.stage != LessonDisputes.CaseStage.PendingTA301) {
            return;
        }
        uint64 next = uint64(
            (c.responseDeadline > vm.getBlockTimestamp() ? c.responseDeadline : vm.getBlockTimestamp()) + 1 days
        );
        vm.prank(ADMIN);
        disputes.extendDeadline(_key(i), c.revision, next, EVIDENCE);
    }

    function finalize(uint8 seed) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.responseDeadline == 0 || vm.getBlockTimestamp() < c.responseDeadline) return;
        if (c.stage == LessonDisputes.CaseStage.AwaitingTutor) {
            vm.prank(RECONCILER);
            disputes.attestNoResponse(_key(i), c.revision, uint64(vm.getBlockTimestamp()), EVIDENCE);
            vm.prank(ENGINE);
            disputes.finalizeNonResponse(_key(i));
        } else if (c.stage == LessonDisputes.CaseStage.PendingTA301) {
            vm.prank(ENGINE);
            disputes.finalizeAcknowledgedTA301(_key(i));
        }
        _snapshot(i);
    }

    function staffDecision(uint8 seed, uint8 outcomeSeed, bool refund) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.stage == LessonDisputes.CaseStage.Resolved) return;
        LessonDisputes.Outcome outcome = LessonDisputes.Outcome(uint8(bound(outcomeSeed, 1, 3)));
        refund = refund || outcome == LessonDisputes.Outcome.TA301;
        vm.prank(ADMIN);
        if (c.stage == LessonDisputes.CaseStage.AwaitingStaff) {
            disputes.resolveByStaff(_key(i), outcome, refund, EVIDENCE);
        } else {
            disputes.overrideActiveCase(_key(i), c.revision, outcome, refund, EVIDENCE);
        }
        _snapshot(i);
    }

    function appeal(uint8 seed, bool past, bool excuse) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.stage != LessonDisputes.CaseStage.Resolved) return;
        vm.prank(ADMIN);
        disputes.reconsider(
            _key(i),
            c.revision,
            past ? LessonDisputes.Outcome.Past : LessonDisputes.Outcome.NoPenalty,
            c.refundApproved,
            excuse && c.nonResponse,
            EVIDENCE
        );
        _snapshot(i);
    }

    function deliverRefund(uint8 seed) external {
        uint256 i = seed % 8;
        if (!opened[i]) return;
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (!c.refundApproved || c.refundReceiptCommitment != bytes32(0)) return;
        vm.prank(ENGINE);
        disputes.recordRefundDelivery(_key(i), EVIDENCE);
        ++refundDeliveryCount[i];
    }

    function _snapshot(uint256 i) private {
        LessonDisputes.DisputeCase memory c = disputes.getCase(_key(i));
        if (c.decisionCount != 0 && firstDecisionHash[i] == bytes32(0)) {
            firstDecisionHash[i] = keccak256(abi.encode(disputes.getDecision(_key(i), 1)));
        }
        refundEverApproved[i] = refundEverApproved[i] || c.refundApproved;
    }

    function _key(uint256 i) private pure returns (bytes32) {
        return bytes32(i + 1);
    }
}

contract LessonDisputesInvariantTest is StdInvariant, Test {
    DisputeHandler internal handler;
    LessonDisputes internal disputes;

    function _sharedRoles() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        handler = new DisputeHandler(_sharedRoles());
        disputes = handler.disputes();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = DisputeHandler.open.selector;
        selectors[1] = DisputeHandler.request.selector;
        selectors[2] = DisputeHandler.reply.selector;
        selectors[3] = DisputeHandler.advance.selector;
        selectors[4] = DisputeHandler.extend.selector;
        selectors[5] = DisputeHandler.finalize.selector;
        selectors[6] = DisputeHandler.staffDecision.selector;
        selectors[7] = DisputeHandler.appeal.selector;
        selectors[8] = DisputeHandler.deliverRefund.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantDecisionRefundAndEvidenceSafety() public view {
        for (uint256 i; i < 8; i++) {
            if (!handler.opened(i)) continue;
            bytes32 key = bytes32(i + 1);
            LessonDisputes.DisputeCase memory c = disputes.getCase(key);
            assertEq(c.complaintCommitment, keccak256("private test evidence"));
            assertEq(c.policyHash, keccak256("policy v1"));
            if (handler.originalReply(i) != bytes32(0)) assertEq(c.responseCommitment, handler.originalReply(i));
            if (handler.refundEverApproved(i)) assertTrue(c.refundApproved);
            assertLe(handler.refundDeliveryCount(i), 1);
            if (c.outcome == LessonDisputes.Outcome.TA301) assertTrue(c.refundApproved);
            assertEq(
                disputes.isTutorPayable(key),
                c.stage == LessonDisputes.CaseStage.Resolved && c.outcome == LessonDisputes.Outcome.NoPenalty
            );
            if (c.stage == LessonDisputes.CaseStage.Resolved) {
                assertGt(c.decisionCount, 0);
                assertTrue(c.outcome != LessonDisputes.Outcome.Unresolved);
                assertEq(keccak256(abi.encode(disputes.getDecision(key, 1))), handler.firstDecisionHash(i));
            } else {
                assertEq(c.decisionCount, 0);
                assertEq(uint256(c.outcome), uint256(LessonDisputes.Outcome.Unresolved));
                assertFalse(c.refundApproved);
            }
        }
    }
}

contract LessonDisputesSharedRolesInvariantTest is LessonDisputesInvariantTest {
    function _sharedRoles() internal pure override returns (bool) {
        return true;
    }
}
