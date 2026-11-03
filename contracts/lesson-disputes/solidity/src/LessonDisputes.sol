// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Private-evidence dispute decisions, not an escrow or an attendance oracle.
/// @dev Engine attests to application records; the reconciler separately attests to drained reply work.
contract LessonDisputes is Ownable2Step {
    using SafeCast for uint256;
    enum CaseStage {
        None,
        AwaitingTutor,
        PendingTA301,
        AwaitingStaff,
        Resolved
    }
    enum Outcome {
        Unresolved,
        TA301,
        NoPenalty,
        Past
    }
    enum CaseKind {
        Standard,
        StaffFirst
    }
    enum ResolutionCause {
        None,
        Staff,
        Duration,
        NonResponse,
        NoShow,
        Override,
        Reconsideration
    }

    struct DisputeCase {
        CaseStage stage;
        Outcome outcome;
        bytes32 complaintCommitment;
        bytes32 responseCommitment;
        bytes32 decisionCommitment;
        bytes32 policyHash;
        uint64 responseDeadline;
        uint64 respondedAt;
        uint64 explanationRequestedAt;
        bool refundApproved;
        bool nonResponse;
        CaseKind kind;
        ResolutionCause cause;
        uint64 originalDeadline;
        uint64 lessonEndedAt;
        uint64 revision;
        uint64 decisionCount;
        uint64 resolvedAt;
        bool nonResponseExcused;
        bytes32 explanationApproval;
        bytes32 reconciliationCommitment;
        bytes32 refundReceiptCommitment;
    }

    struct Decision {
        Outcome outcome;
        ResolutionCause cause;
        bool refundApproved;
        bool nonResponse;
        bool nonResponseExcused;
        bytes32 commitment;
        address actor;
        uint64 recordedAt;
        uint64 caseRevision;
    }

    struct NoResponseAttestation {
        bytes32 commitment;
        uint64 checkedThrough;
        uint64 caseRevision;
        uint64 configurationEpoch;
    }

    mapping(bytes32 => DisputeCase) private cases;
    mapping(bytes32 => mapping(uint64 => Decision)) private decisions;
    mapping(bytes32 => NoResponseAttestation) private attestations;
    mapping(bytes32 => bool) public approvedPolicies;

    address public engine;
    address public pendingEngine;
    address public reconciler;
    address public pendingReconciler;
    bool public paused = true;
    bool public nonResponseEnabled;
    uint64 public configurationEpoch = 1;
    uint64 public constant RESPONSE_WINDOW = 24 hours;

    error ZeroAddress();
    error Unauthorized();
    error RoleOverlap();
    error RenunciationDisabled();
    error PauseStateUnchanged();
    error ContractPaused();
    error InvalidCommitment();
    error PolicyNotApproved();
    error CaseAlreadyExists();
    error CaseNotFound();
    error ExplanationAlreadyRequested();
    error StaffApprovalRequired();
    error ResponseAlreadySubmitted();
    error DeadlineNotReached();
    error InvalidRequestTime();
    error InvalidCaseStage();
    error InvalidResponseTime();
    error InvalidDecision();
    error InvalidReconciliation();
    error NonResponseDisabled();
    error StaleRevision();
    error RefundAlreadyRecorded();
    error RefundNotApproved();
    error DecisionNotFound();

    event PauseChanged(bool paused);
    event EngineProposed(address indexed candidate);
    event EngineChanged(address indexed previousEngine, address indexed newEngine);
    event ReconcilerProposed(address indexed candidate);
    event ReconcilerChanged(address indexed previousReconciler, address indexed newReconciler);
    event NonResponseEnabledChanged(bool enabled, uint64 configurationEpoch);
    event PolicyStatusChanged(bytes32 indexed policyHash, bool approved);
    event CaseOpened(bytes32 indexed lessonKey, bytes32 complaintCommitment, bytes32 policyHash);
    event CaseKindRecorded(bytes32 indexed lessonKey, CaseKind kind);
    event ExplanationAuthorized(bytes32 indexed lessonKey, bytes32 approvalCommitment);
    event ExplanationRequested(bytes32 indexed lessonKey, uint64 responseDeadline);
    event DeadlineExtended(bytes32 indexed lessonKey, uint64 previousDeadline, uint64 newDeadline, bytes32 reason);
    event ResponseRecorded(bytes32 indexed lessonKey, bytes32 responseCommitment, uint64 receivedAt);
    event NoResponseAttested(bytes32 indexed lessonKey, bytes32 commitment, uint64 revision, uint64 checkedThrough);
    event NoShowRecorded(bytes32 indexed lessonKey, bytes32 evidenceCommitment, uint64 checkedThrough);
    event CaseResolved(bytes32 indexed lessonKey, Outcome outcome, bool refundApproved, bool nonResponse);
    event StaffDecisionRecorded(bytes32 indexed lessonKey, bytes32 decisionCommitment);
    event DecisionRecorded(bytes32 indexed lessonKey, uint64 indexed decisionNumber, uint64 revision);
    event RefundDeliveryRecorded(bytes32 indexed lessonKey, bytes32 indexed instructionId, bytes32 receiptCommitment);

    modifier onlyEngine() {
        if (msg.sender != engine) revert Unauthorized();
        _;
    }

    modifier onlyAdministrator() {
        if (msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address administrator_, address engine_) Ownable(_validateRoles(administrator_, engine_)) {
        engine = engine_;
    }

    function administrator() external view returns (address) {
        return owner();
    }

    function transferOwnership(address candidate) public override onlyOwner {
        if (candidate != address(0) && _reconciliationRole(candidate)) revert RoleOverlap();
        super.transferOwnership(candidate);
    }

    function acceptOwnership() public override {
        if (_reconciliationRole(msg.sender)) revert RoleOverlap();
        super.acceptOwnership();
        _invalidateConfiguration();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }

    function proposeEngine(address candidate) external onlyAdministrator {
        if (candidate == address(0)) revert ZeroAddress();
        if (_reconciliationRole(candidate)) {
            revert RoleOverlap();
        }
        pendingEngine = candidate;
        emit EngineProposed(pendingEngine);
    }

    function acceptEngine() external {
        if (pendingEngine == address(0) || msg.sender != pendingEngine) revert Unauthorized();
        address previous = engine;
        engine = msg.sender;
        pendingEngine = address(0);
        emit EngineProposed(pendingEngine);
        _invalidateConfiguration();
        emit EngineChanged(previous, msg.sender);
    }

    function proposeReconciler(address candidate) external onlyAdministrator {
        if (candidate == address(0)) revert ZeroAddress();
        if (candidate == owner() || candidate == pendingOwner() || candidate == engine || candidate == pendingEngine) {
            revert RoleOverlap();
        }
        pendingReconciler = candidate;
        emit ReconcilerProposed(pendingReconciler);
    }

    function acceptReconciler() external {
        if (pendingReconciler == address(0) || msg.sender != pendingReconciler) revert Unauthorized();
        address previous = reconciler;
        reconciler = msg.sender;
        pendingReconciler = address(0);
        emit ReconcilerProposed(pendingReconciler);
        _invalidateConfiguration();
        emit ReconcilerChanged(previous, msg.sender);
    }

    function setNonResponseEnabled(bool enabled) external onlyAdministrator {
        if (enabled && reconciler == address(0)) revert NonResponseDisabled();
        nonResponseEnabled = enabled;
        ++configurationEpoch;
        emit NonResponseEnabledChanged(enabled, configurationEpoch);
    }

    function setPaused(bool paused_) external onlyAdministrator {
        if (paused == paused_) revert PauseStateUnchanged();
        paused = paused_;
        // An incident invalidates previously prepared timeout assertions.
        ++configurationEpoch;
        emit PauseChanged(paused_);
    }

    function setPolicyStatus(bytes32 policyHash, bool approved) external onlyAdministrator {
        if (policyHash == bytes32(0)) revert InvalidCommitment();
        approvedPolicies[policyHash] = approved;
        emit PolicyStatusChanged(policyHash, approved);
    }

    function openCase(bytes32 lessonKey, bytes32 complaintCommitment, bytes32 policyHash)
        external
        onlyEngine
        whenNotPaused
    {
        _openCase(lessonKey, complaintCommitment, policyHash, CaseKind.Standard);
    }

    function openStaffReviewCase(bytes32 lessonKey, bytes32 complaintCommitment, bytes32 policyHash)
        external
        onlyEngine
        whenNotPaused
    {
        _openCase(lessonKey, complaintCommitment, policyHash, CaseKind.StaffFirst);
    }

    function authorizeExplanation(bytes32 lessonKey, uint64 expectedRevision, bytes32 approvalCommitment)
        external
        onlyAdministrator
        whenNotPaused
    {
        DisputeCase storage dispute = _case(lessonKey);
        _expectRevision(dispute, expectedRevision);
        if (dispute.stage != CaseStage.AwaitingStaff || dispute.responseDeadline != 0) revert InvalidCaseStage();
        if (dispute.explanationApproval != bytes32(0)) revert ExplanationAlreadyRequested();
        if (approvalCommitment == bytes32(0)) revert InvalidCommitment();
        dispute.explanationApproval = approvalCommitment;
        _touch(lessonKey, dispute);
        emit ExplanationAuthorized(lessonKey, approvalCommitment);
    }

    function requestExplanation(bytes32 lessonKey, uint64 lessonEndedAt, uint64 requestCreatedAt)
        external
        onlyEngine
        whenNotPaused
    {
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.responseDeadline != 0) revert ExplanationAlreadyRequested();
        if (dispute.stage != CaseStage.AwaitingStaff) revert InvalidCaseStage();
        if (dispute.kind == CaseKind.StaffFirst && dispute.explanationApproval == bytes32(0)) {
            revert StaffApprovalRequired();
        }
        if (lessonEndedAt == 0 || requestCreatedAt < lessonEndedAt || requestCreatedAt > block.timestamp) {
            revert InvalidRequestTime();
        }
        uint256 deadline = uint256(requestCreatedAt) + RESPONSE_WINDOW;
        if (deadline > type(uint64).max) revert InvalidRequestTime();
        // Historical requests are allowed: blockchain delay must not restart an inbox deadline.
        dispute.responseDeadline = deadline.toUint64();
        dispute.originalDeadline = deadline.toUint64();
        dispute.explanationRequestedAt = requestCreatedAt;
        dispute.lessonEndedAt = lessonEndedAt;
        dispute.stage = CaseStage.AwaitingTutor;
        _touch(lessonKey, dispute);
        emit ExplanationRequested(lessonKey, deadline.toUint64());
    }

    function extendDeadline(bytes32 lessonKey, uint64 expectedRevision, uint64 newDeadline, bytes32 reason)
        external
        onlyAdministrator
    {
        DisputeCase storage dispute = _case(lessonKey);
        _expectRevision(dispute, expectedRevision);
        if (dispute.stage != CaseStage.AwaitingTutor && dispute.stage != CaseStage.PendingTA301) {
            revert InvalidCaseStage();
        }
        if (reason == bytes32(0)) revert InvalidCommitment();
        if (newDeadline <= dispute.responseDeadline || newDeadline <= block.timestamp) revert InvalidRequestTime();
        uint64 previous = dispute.responseDeadline;
        dispute.responseDeadline = newDeadline;
        _touch(lessonKey, dispute);
        emit DeadlineExtended(lessonKey, previous, newDeadline, reason);
    }

    function recordResponse(bytes32 lessonKey, bytes32 responseCommitment, uint64 receivedAt, bool automaticTA301)
        external
        onlyEngine
    {
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.responseCommitment != bytes32(0)) revert ResponseAlreadySubmitted();
        if (dispute.stage != CaseStage.AwaitingTutor) revert InvalidCaseStage();
        if (responseCommitment == bytes32(0)) revert InvalidCommitment();
        if (
            receivedAt < dispute.explanationRequestedAt || receivedAt >= dispute.responseDeadline
                || receivedAt > block.timestamp
        ) {
            revert InvalidResponseTime();
        }
        if (automaticTA301 && dispute.kind == CaseKind.StaffFirst) revert InvalidDecision();
        dispute.responseCommitment = responseCommitment;
        dispute.respondedAt = receivedAt;
        dispute.stage = automaticTA301 ? CaseStage.PendingTA301 : CaseStage.AwaitingStaff;
        _touch(lessonKey, dispute);
        emit ResponseRecorded(lessonKey, responseCommitment, receivedAt);
    }

    function finalizeAcknowledgedTA301(bytes32 lessonKey) external onlyEngine whenNotPaused {
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.stage != CaseStage.PendingTA301 || dispute.responseCommitment == bytes32(0)) {
            revert InvalidCaseStage();
        }
        if (block.timestamp < dispute.responseDeadline) revert DeadlineNotReached();
        _resolve(lessonKey, dispute, Outcome.TA301, true, ResolutionCause.Duration, dispute.responseCommitment);
    }

    /// @dev An assertion of reconciliation, not a ZK proof of absence. Do not sign while timely replies remain queued.
    function attestNoResponse(bytes32 lessonKey, uint64 expectedRevision, uint64 checkedThrough, bytes32 commitment)
        external
        whenNotPaused
    {
        if (reconciler == address(0) || msg.sender != reconciler) revert Unauthorized();
        if (!nonResponseEnabled) revert NonResponseDisabled();
        DisputeCase storage dispute = _case(lessonKey);
        _expectRevision(dispute, expectedRevision);
        if (dispute.stage != CaseStage.AwaitingTutor || dispute.responseCommitment != bytes32(0)) {
            revert InvalidCaseStage();
        }
        if (block.timestamp < dispute.responseDeadline) revert DeadlineNotReached();
        if (commitment == bytes32(0) || checkedThrough < dispute.responseDeadline || checkedThrough > block.timestamp) {
            revert InvalidReconciliation();
        }
        attestations[lessonKey] =
            NoResponseAttestation(commitment, checkedThrough, dispute.revision, configurationEpoch);
        emit NoResponseAttested(lessonKey, commitment, dispute.revision, checkedThrough);
    }

    function finalizeNonResponse(bytes32 lessonKey) external onlyEngine whenNotPaused {
        if (!nonResponseEnabled) revert NonResponseDisabled();
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.stage != CaseStage.AwaitingTutor || dispute.responseCommitment != bytes32(0)) {
            revert InvalidCaseStage();
        }
        if (block.timestamp < dispute.responseDeadline) revert DeadlineNotReached();
        NoResponseAttestation memory attestation = attestations[lessonKey];
        if (
            attestation.commitment == bytes32(0) || attestation.caseRevision != dispute.revision
                || attestation.configurationEpoch != configurationEpoch
        ) {
            revert InvalidReconciliation();
        }
        dispute.nonResponse = true;
        dispute.reconciliationCommitment = attestation.commitment;
        _resolve(lessonKey, dispute, Outcome.TA301, true, ResolutionCause.NonResponse, attestation.commitment);
    }

    function resolveByStaff(bytes32 lessonKey, Outcome outcome, bool refundApproved, bytes32 decisionCommitment)
        external
        onlyAdministrator
        whenNotPaused
    {
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.stage != CaseStage.AwaitingStaff) revert InvalidCaseStage();
        _resolve(lessonKey, dispute, outcome, refundApproved, ResolutionCause.Staff, decisionCommitment);
        emit StaffDecisionRecorded(lessonKey, decisionCommitment);
    }

    function overrideActiveCase(
        bytes32 lessonKey,
        uint64 expectedRevision,
        Outcome outcome,
        bool refundApproved,
        bytes32 reason
    ) external onlyAdministrator whenNotPaused {
        DisputeCase storage dispute = _case(lessonKey);
        _expectRevision(dispute, expectedRevision);
        if (dispute.stage == CaseStage.Resolved) revert InvalidCaseStage();
        _resolve(lessonKey, dispute, outcome, refundApproved, ResolutionCause.Override, reason);
        emit StaffDecisionRecorded(lessonKey, reason);
    }

    function reconsider(
        bytes32 lessonKey,
        uint64 expectedRevision,
        Outcome outcome,
        bool refundApproved,
        bool excuseNonResponse,
        bytes32 reason
    ) external onlyAdministrator whenNotPaused {
        DisputeCase storage dispute = _case(lessonKey);
        _expectRevision(dispute, expectedRevision);
        if (dispute.stage != CaseStage.Resolved) revert InvalidCaseStage();
        if (excuseNonResponse && !dispute.nonResponse) revert InvalidDecision();
        if (excuseNonResponse) dispute.nonResponseExcused = true;
        _resolve(lessonKey, dispute, outcome, refundApproved, ResolutionCause.Reconsideration, reason);
        emit StaffDecisionRecorded(lessonKey, reason);
    }

    /// @notice Independent full-lesson no-entry evidence; never infer this from the five-minute statistics flag.
    function resolveNoShow(
        bytes32 lessonKey,
        bytes32 evidenceCommitment,
        bytes32 policyHash,
        uint64 lessonEndedAt,
        uint64 checkedThrough
    ) external onlyEngine whenNotPaused {
        if (evidenceCommitment == bytes32(0)) revert InvalidCommitment();
        if (lessonEndedAt == 0 || checkedThrough < lessonEndedAt || checkedThrough > block.timestamp) {
            revert InvalidReconciliation();
        }
        if (cases[lessonKey].stage == CaseStage.None) {
            _openCase(lessonKey, evidenceCommitment, policyHash, CaseKind.Standard);
        }
        DisputeCase storage dispute = _case(lessonKey);
        if (dispute.stage == CaseStage.Resolved) revert InvalidCaseStage();
        if (policyHash != dispute.policyHash) revert InvalidCommitment();
        if (dispute.lessonEndedAt != 0 && dispute.lessonEndedAt != lessonEndedAt) revert InvalidRequestTime();
        dispute.lessonEndedAt = lessonEndedAt;
        _resolve(lessonKey, dispute, Outcome.TA301, true, ResolutionCause.NoShow, evidenceCommitment);
        emit NoShowRecorded(lessonKey, evidenceCommitment, checkedThrough);
    }

    /// @notice Records the Engine's external-delivery receipt; does not execute or independently verify a refund.
    function recordRefundDelivery(bytes32 lessonKey, bytes32 receiptCommitment) external onlyEngine {
        DisputeCase storage dispute = _case(lessonKey);
        if (!dispute.refundApproved) revert RefundNotApproved();
        if (dispute.refundReceiptCommitment != bytes32(0)) revert RefundAlreadyRecorded();
        if (receiptCommitment == bytes32(0)) revert InvalidCommitment();
        dispute.refundReceiptCommitment = receiptCommitment;
        _touch(lessonKey, dispute);
        emit RefundDeliveryRecorded(lessonKey, refundInstructionId(lessonKey), receiptCommitment);
    }

    function refundInstructionId(bytes32 lessonKey) public view returns (bytes32) {
        _case(lessonKey);
        return keccak256(abi.encode("FXV_REFUND_V1", block.chainid, address(this), lessonKey));
    }

    function isTutorPayable(bytes32 lessonKey) external view returns (bool) {
        DisputeCase storage dispute = _case(lessonKey);
        return dispute.stage == CaseStage.Resolved && dispute.outcome == Outcome.NoPenalty;
    }

    function getCase(bytes32 lessonKey) external view returns (DisputeCase memory) {
        return _case(lessonKey);
    }

    function getDecision(bytes32 lessonKey, uint64 number) external view returns (Decision memory) {
        DisputeCase storage dispute = _case(lessonKey);
        if (number == 0 || number > dispute.decisionCount) revert DecisionNotFound();
        return decisions[lessonKey][number];
    }

    function getNoResponseAttestation(bytes32 lessonKey) external view returns (NoResponseAttestation memory) {
        _case(lessonKey);
        return attestations[lessonKey];
    }

    function _openCase(bytes32 lessonKey, bytes32 complaintCommitment, bytes32 policyHash, CaseKind kind) private {
        if (lessonKey == bytes32(0) || complaintCommitment == bytes32(0) || policyHash == bytes32(0)) {
            revert InvalidCommitment();
        }
        if (cases[lessonKey].stage != CaseStage.None) revert CaseAlreadyExists();
        if (!approvedPolicies[policyHash]) revert PolicyNotApproved();
        DisputeCase storage dispute = cases[lessonKey];
        dispute.complaintCommitment = complaintCommitment;
        dispute.policyHash = policyHash;
        dispute.kind = kind;
        dispute.stage = CaseStage.AwaitingStaff;
        dispute.revision = 1;
        emit CaseOpened(lessonKey, complaintCommitment, policyHash);
        emit CaseKindRecorded(lessonKey, kind);
    }

    function _resolve(
        bytes32 lessonKey,
        DisputeCase storage dispute,
        Outcome outcome,
        bool refundApproved,
        ResolutionCause cause,
        bytes32 commitment
    ) private {
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (outcome == Outcome.Unresolved || (outcome == Outcome.TA301 && !refundApproved)) revert InvalidDecision();
        if (dispute.refundApproved && !refundApproved) revert InvalidDecision();
        dispute.stage = CaseStage.Resolved;
        dispute.outcome = outcome;
        dispute.refundApproved = refundApproved;
        dispute.decisionCommitment = commitment;
        dispute.cause = cause;
        dispute.resolvedAt = _now64();
        _touch(lessonKey, dispute);
        uint64 number = ++dispute.decisionCount;
        decisions[lessonKey][number] = Decision(
            outcome,
            cause,
            refundApproved,
            dispute.nonResponse,
            dispute.nonResponseExcused,
            commitment,
            msg.sender,
            dispute.resolvedAt,
            dispute.revision
        );
        emit DecisionRecorded(lessonKey, number, dispute.revision);
        emit CaseResolved(lessonKey, outcome, refundApproved, dispute.nonResponse);
    }

    function _case(bytes32 lessonKey) private view returns (DisputeCase storage dispute) {
        dispute = cases[lessonKey];
        if (dispute.stage == CaseStage.None) revert CaseNotFound();
    }

    function _touch(bytes32 lessonKey, DisputeCase storage dispute) private {
        ++dispute.revision;
        delete attestations[lessonKey];
    }

    function _expectRevision(DisputeCase storage dispute, uint64 expectedRevision) private view {
        if (dispute.revision != expectedRevision) revert StaleRevision();
    }

    function _invalidateConfiguration() private {
        nonResponseEnabled = false;
        ++configurationEpoch;
        emit NonResponseEnabledChanged(false, configurationEpoch);
    }

    function _reconciliationRole(address candidate) private view returns (bool) {
        return candidate == reconciler || candidate == pendingReconciler;
    }

    function _validateRoles(address administrator_, address engine_) private pure returns (address) {
        if (administrator_ == address(0) || engine_ == address(0)) revert ZeroAddress();
        return administrator_;
    }

    function _now64() private view returns (uint64) {
        if (block.timestamp > type(uint64).max) revert InvalidRequestTime();
        return block.timestamp.toUint64();
    }
}
