// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { SignatureChecker } from "../lib/common/src/SignatureChecker.sol";
import { ERC712 } from "../lib/common/src/ERC712.sol";

import { SPOGRegistrarReader } from "./libs/SPOGRegistrarReader.sol";

import { IContinuousIndexing } from "./interfaces/IContinuousIndexing.sol";
import { IMToken } from "./interfaces/IMToken.sol";
import { IProtocol } from "./interfaces/IProtocol.sol";
import { IRateModel } from "./interfaces/IRateModel.sol";

import { ContinuousIndexing } from "./ContinuousIndexing.sol";

/**
 * @title Protocol
 * @author M^ZERO LABS_
 * @notice Core protocol of M^ZERO ecosystem. 
           Minting Gateway of M Token for all approved by SPOG and activated minters.
 */
contract Protocol is IProtocol, ContinuousIndexing, ERC712 {
    // TODO: bit-packing
    struct MintProposal {
        uint256 id; // TODO: uint96 or uint48 if 2 additional fields
        address destination;
        uint256 amount;
        uint256 createdAt;
    }

    /******************************************************************************************************************\
    |                                                    Variables                                                     |
    \******************************************************************************************************************/

    uint256 public constant ONE = 10_000; // 100% in basis points.

    // keccak256("UpdateCollateral(address minter,uint256 collateral,uint256[] retrievalIds,bytes32 metadataHash,uint256 timestamp)")
    bytes32 public constant UPDATE_COLLATERAL_TYPEHASH =
        0x22b57ca54bd15c6234b29e87aa1d76a0841b6e65e63d7acacef989de0bc3ff9e;

    /// @inheritdoc IProtocol
    address public immutable spogRegistrar;

    /// @inheritdoc IProtocol
    address public immutable spogVault;

    /// @inheritdoc IProtocol
    address public immutable mToken;

    /// @notice Nonce used to generate unique mint proposal IDs.
    uint256 internal _mintNonce;

    /// @notice Nonce used to generate unique retrieval proposal IDs.
    uint256 internal _retrievalNonce;

    /// @notice The total principal amount of active M
    uint256 internal _totalPrincipalOfActiveOwedM;

    /// @notice The total amount of inactive M, sum of all inactive minter's owed M
    uint256 internal _totalInactiveOwedM;

    mapping(address minter => bool isActiveMinter) internal _isActiveMinter;

    mapping(address minter => MintProposal proposal) internal _mintProposals;

    mapping(address minter => uint256 amount) internal _inactiveOwedM;
    mapping(address minter => uint256 principal) internal _principalOfActiveOwedM;

    mapping(address minter => uint256 collateral) internal _collaterals;
    mapping(address minter => uint256 updateInterval) internal _lastUpdateIntervals;
    mapping(address minter => uint256 timestamp) internal _lastCollateralUpdates;
    mapping(address minter => uint256 timestamp) internal _penalizedUntilTimestamps;

    mapping(address minter => uint256 collateral) internal _totalPendingCollateralRetrievals;
    mapping(address minter => mapping(uint256 retrievalId => uint256 amount)) internal _pendingCollateralRetrievals;

    mapping(address minter => uint256 timestamp) internal _unfrozenTimestamps;

    /******************************************************************************************************************\
    |                                            Modifiers and Constructor                                             |
    \******************************************************************************************************************/

    /// @notice Only allow active minter to call function.
    modifier onlyActiveMinter() {
        _revertIfInactiveMinter(msg.sender);

        _;
    }

    /// @notice Only allow approved validator in SPOG to call function.
    modifier onlyApprovedValidator() {
        _revertIfNotApprovedValidator(msg.sender);

        _;
    }

    /// @notice Only allow unfrozen minter to call function.
    modifier onlyUnfrozenMinter() {
        _revertIfMinterFrozen(msg.sender);

        _;
    }

    /**
     * @notice Constructor.
     * @param spogRegistrar_ The address of the SPOG Registrar contract.
     * @param mToken_ The address of the M Token.
     */
    constructor(address spogRegistrar_, address mToken_) ContinuousIndexing() ERC712("Protocol") {
        if ((spogRegistrar = spogRegistrar_) == address(0)) revert ZeroSpogRegistrar();
        if ((spogVault = SPOGRegistrarReader.getVault(spogRegistrar_)) == address(0)) revert ZeroSpogVault();
        if ((mToken = mToken_) == address(0)) revert ZeroMToken();
    }

    /******************************************************************************************************************\
    |                                          External Interactive Functions                                          |
    \******************************************************************************************************************/

    /// @inheritdoc IProtocol
    function updateCollateral(
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        address[] calldata validators_,
        uint256[] calldata timestamps_,
        bytes[] calldata signatures_
    ) external onlyActiveMinter returns (uint256 minTimestamp_) {
        if (validators_.length != signatures_.length || signatures_.length != timestamps_.length) {
            revert SignatureArrayLengthsMismatch();
        }

        // Verify that enough valid signatures are provided, and get the minimum timestamp across all valid signatures.
        minTimestamp_ = _verifyValidatorSignatures(
            msg.sender,
            collateral_,
            retrievalIds_,
            metadataHash_,
            validators_,
            timestamps_,
            signatures_
        );

        emit CollateralUpdated(msg.sender, collateral_, retrievalIds_, metadataHash_, minTimestamp_);

        _resolvePendingRetrievals(msg.sender, retrievalIds_);

        _imposePenaltyIfMissedCollateralUpdates(msg.sender);

        _updateCollateral(msg.sender, collateral_, minTimestamp_);

        _imposePenaltyIfUndercollateralized(msg.sender);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IProtocol
    function proposeRetrieval(uint256 collateral_) external onlyActiveMinter returns (uint256 retrievalId_) {
        unchecked {
            retrievalId_ = ++_retrievalNonce;
        }

        _totalPendingCollateralRetrievals[msg.sender] += collateral_;
        _pendingCollateralRetrievals[msg.sender][retrievalId_] = collateral_;

        _revertIfUndercollateralized(msg.sender, 0);

        emit RetrievalCreated(retrievalId_, msg.sender, collateral_);
    }

    /// @inheritdoc IProtocol
    function proposeMint(
        uint256 amount_,
        address destination_
    ) external onlyActiveMinter onlyUnfrozenMinter returns (uint256 mintId_) {
        _revertIfUndercollateralized(msg.sender, amount_); // Check that minter will remain sufficiently collateralized.

        unchecked {
            mintId_ = ++_mintNonce;
        }

        _mintProposals[msg.sender] = MintProposal(mintId_, destination_, amount_, block.timestamp);

        emit MintProposed(mintId_, msg.sender, amount_, destination_);
    }

    /// @inheritdoc IProtocol
    function mintM(uint256 mintId_) external onlyActiveMinter onlyUnfrozenMinter {
        MintProposal storage mintProposal_ = _mintProposals[msg.sender];

        (uint256 id_, uint256 amount_, uint256 createdAt_, address destination_) = (
            mintProposal_.id,
            mintProposal_.amount,
            mintProposal_.createdAt,
            mintProposal_.destination
        );

        if (id_ != mintId_) revert InvalidMintProposal();

        // Check that mint proposal is executable.
        uint256 activeAt_ = createdAt_ + mintDelay();
        if (block.timestamp < activeAt_) revert PendingMintProposal(activeAt_);

        uint256 expiresAt_ = activeAt_ + mintTTL();
        if (block.timestamp > expiresAt_) revert ExpiredMintProposal(expiresAt_);

        _revertIfUndercollateralized(msg.sender, amount_); // Check that minter will remain sufficiently collateralized.

        delete _mintProposals[msg.sender]; // Delete mint request.

        emit MintExecuted(mintId_);

        // Adjust principal of active owed M for minter.
        uint256 principalAmount_ = _getPrincipalValue(amount_);
        _principalOfActiveOwedM[msg.sender] += principalAmount_;
        _totalPrincipalOfActiveOwedM += principalAmount_;

        IMToken(mToken).mint(destination_, amount_);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the mint
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IProtocol
    function burnM(address minter_, uint256 maxAmount_) external {
        // NOTE: Penalize only for missed collateral updates, not for undercollateralization.
        // Undercollateralization within one update interval is forgiven.
        _imposePenaltyIfMissedCollateralUpdates(minter_);

        uint256 amount_ = _isActiveMinter[minter_]
            ? _repayForActiveMinter(minter_, maxAmount_)
            : _repayForInactiveMinter(minter_, maxAmount_);

        emit BurnExecuted(minter_, amount_, msg.sender);

        IMToken(mToken).burn(msg.sender, amount_); // Burn actual M tokens

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the burn
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IProtocol
    function cancelMint(address minter_, uint256 mintId_) external onlyApprovedValidator {
        if (_mintProposals[minter_].id != mintId_) revert InvalidMintProposal();

        delete _mintProposals[minter_];

        emit MintCanceled(mintId_, msg.sender);
    }

    /// @inheritdoc IProtocol
    function freezeMinter(address minter_) external onlyApprovedValidator returns (uint256 frozenUntil_) {
        _revertIfInactiveMinter(minter_);

        frozenUntil_ = block.timestamp + minterFreezeTime();

        emit MinterFrozen(minter_, _unfrozenTimestamps[minter_] = frozenUntil_);
    }

    /// @inheritdoc IProtocol
    function activateMinter(address minter_) external {
        if (!isMinterApprovedBySPOG(minter_)) revert NotApprovedMinter();
        if (_isActiveMinter[minter_]) revert AlreadyActiveMinter();

        _isActiveMinter[minter_] = true;

        emit MinterActivated(minter_, msg.sender);
    }

    /// @inheritdoc IProtocol
    function deactivateMinter(address minter_) external returns (uint256 inactiveOwedM_) {
        if (isMinterApprovedBySPOG(minter_)) revert StillApprovedMinter();

        _revertIfInactiveMinter(minter_);

        // NOTE: Instead of imposing, calculate penalty and add it to `_inactiveOwedM` to save gas.
        inactiveOwedM_ = activeOwedMOf(minter_) + getPenaltyForMissedCollateralUpdates(minter_);

        emit MinterDeactivated(minter_, inactiveOwedM_, msg.sender);

        _inactiveOwedM[minter_] += inactiveOwedM_;
        _totalInactiveOwedM += inactiveOwedM_;

        // Adjust total principal of owed M.
        _totalPrincipalOfActiveOwedM -= _principalOfActiveOwedM[minter_];

        // Reset reasonable aspects of minter's state.
        delete _isActiveMinter[minter_];
        delete _collaterals[minter_];
        delete _lastUpdateIntervals[minter_];
        delete _lastCollateralUpdates[minter_];
        delete _mintProposals[minter_];
        delete _penalizedUntilTimestamps[minter_];
        delete _principalOfActiveOwedM[minter_];
        delete _unfrozenTimestamps[minter_];

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the
        //       deactivation can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IContinuousIndexing
    function updateIndex() public override(IContinuousIndexing, ContinuousIndexing) returns (uint256 index_) {
        // NOTE: Since the currentIndex of the protocol and mToken are constant thought this context's execution (since
        //       the block.timestamp is not changing) we can compute excessOwedM without updating the mToken index.
        uint256 excessOwedM_ = excessActiveOwedM();

        if (excessOwedM_ > 0) IMToken(mToken).mint(spogVault, excessOwedM_); // Mint M to SPOG Vault.

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        // NOTE: With the current rate models, the minter rate does not depend on anything in the protocol or mToken, so
        //       we can update the minter rate and index here.
        index_ = super.updateIndex(); // Update minter index and rate.

        // NOTE: Given the current implementation of the mToken transfers and its rate model, while it is possible for
        //       the above mint to already have updated the mToken index if M was minted to an earning account, we want
        //       to ensure the rate provided by the mToken's rate model is locked in.
        IMToken(mToken).updateIndex(); // Update earning index and rate.
    }

    /******************************************************************************************************************\
    |                                           External View/Pure Functions                                           |
    \******************************************************************************************************************/

    /// @inheritdoc IProtocol
    function totalActiveOwedM() public view returns (uint256 totalActiveOwedM_) {
        return _getPresentValue(_totalPrincipalOfActiveOwedM);
    }

    /// @inheritdoc IProtocol
    function totalInactiveOwedM() public view returns (uint256 totalInactiveOwedM_) {
        return _totalInactiveOwedM;
    }

    /// @inheritdoc IProtocol
    function totalOwedM() external view returns (uint256 totalOwedM_) {
        return totalActiveOwedM() + totalInactiveOwedM();
    }

    /// @inheritdoc IProtocol
    function excessActiveOwedM() public view returns (uint256 getExcessOwedM_) {
        uint256 totalMSupply_ = IMToken(mToken).totalSupply();
        uint256 totalActiveOwedM_ = _getPresentValue(_totalPrincipalOfActiveOwedM);

        if (totalActiveOwedM_ > totalMSupply_) return totalActiveOwedM_ - totalMSupply_;
    }

    /// @inheritdoc IProtocol
    function minterRate() external view returns (uint256 minterRate_) {
        return _latestRate;
    }

    /// @inheritdoc IProtocol
    function activeOwedMOf(address minter_) public view returns (uint256 activeOwedM_) {
        // TODO: This should also include the present value of unavoidable penalities. But then it would be very, if not
        //       impossible, to determine the `totalActiveOwedM` to the same standards. Perhaps we need a `penaltiesOf`
        //       external function to provide the present value of unavoidable penalities
        return _getPresentValue(_principalOfActiveOwedM[minter_]);
    }

    /// @inheritdoc IProtocol
    function maxAllowedActiveOwedMOf(address minter_) public view returns (uint256 maxAllowedOwedM_) {
        return (collateralOf(minter_) * mintRatio()) / ONE;
    }

    /// @inheritdoc IProtocol
    function inactiveOwedMOf(address minter_) external view returns (uint256 inactiveOwedM_) {
        return _inactiveOwedM[minter_];
    }

    /// @inheritdoc IProtocol
    function collateralOf(address minter_) public view returns (uint256 collateral_) {
        // If collateral was not updated before deadline, assume that minter's collateral is zero.
        return
            block.timestamp < collateralUpdateDeadlineOf(minter_)
                ? _collaterals[minter_] - _totalPendingCollateralRetrievals[minter_]
                : 0;
    }

    /// @inheritdoc IProtocol
    function collateralUpdateOf(address minter_) external view returns (uint256 lastUpdate_) {
        return _lastCollateralUpdates[minter_];
    }

    /// @inheritdoc IProtocol
    function collateralUpdateDeadlineOf(address minter_) public view returns (uint256 updateDeadline_) {
        return _lastCollateralUpdates[minter_] + _lastUpdateIntervals[minter_];
    }

    /// @inheritdoc IProtocol
    function lastCollateralUpdateIntervalOf(address minter_) external view returns (uint256 lastUpdateInterval_) {
        return _lastUpdateIntervals[minter_];
    }

    /// @inheritdoc IProtocol
    function penalizedUntilOf(address minter_) external view returns (uint256 penalizedUntil_) {
        return _penalizedUntilTimestamps[minter_];
    }

    /// @inheritdoc IProtocol
    function getPenaltyForMissedCollateralUpdates(address minter_) public view returns (uint256 penalty_) {
        (uint256 penaltyBase_, ) = _getPenaltyBaseAndTimeForMissedCollateralUpdates(minter_);

        return (penaltyBase_ * penaltyRate()) / ONE;
    }

    /// @inheritdoc IProtocol
    function mintProposalOf(
        address minter_
    ) external view returns (uint256 mintId_, address destination_, uint256 amount_, uint256 createdAt_) {
        mintId_ = _mintProposals[minter_].id;
        destination_ = _mintProposals[minter_].destination;
        amount_ = _mintProposals[minter_].amount;
        createdAt_ = _mintProposals[minter_].createdAt;
    }

    /// @inheritdoc IProtocol
    function pendingCollateralRetrievalOf(
        address minter_,
        uint256 retrievalId_
    ) external view returns (uint256 collateral) {
        return _pendingCollateralRetrievals[minter_][retrievalId_];
    }

    /// @inheritdoc IProtocol
    function totalPendingCollateralRetrievalsOf(address minter_) external view returns (uint256 collateral_) {
        return _totalPendingCollateralRetrievals[minter_];
    }

    /// @inheritdoc IProtocol
    function unfrozenTimeOf(address minter_) external view returns (uint256 timestamp_) {
        return _unfrozenTimestamps[minter_];
    }

    /******************************************************************************************************************\
    |                                       SPOG Registrar Reader Functions                                            |
    \******************************************************************************************************************/
    /// @inheritdoc IProtocol
    function isActiveMinter(address minter_) external view returns (bool isActive_) {
        return _isActiveMinter[minter_];
    }

    /// @inheritdoc IProtocol
    function isMinterApprovedBySPOG(address minter_) public view returns (bool isApproved_) {
        return SPOGRegistrarReader.isApprovedMinter(spogRegistrar, minter_);
    }

    /// @inheritdoc IProtocol
    function isValidatorApprovedBySPOG(address validator_) public view returns (bool isApproved_) {
        return SPOGRegistrarReader.isApprovedValidator(spogRegistrar, validator_);
    }

    /// @inheritdoc IProtocol
    function updateCollateralInterval() public view returns (uint256 updateCollateralInterval_) {
        return SPOGRegistrarReader.getUpdateCollateralInterval(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function updateCollateralValidatorThreshold() public view returns (uint256 threshold_) {
        return SPOGRegistrarReader.getUpdateCollateralValidatorThreshold(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function mintRatio() public view returns (uint256 mintRatio_) {
        return SPOGRegistrarReader.getMintRatio(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function mintDelay() public view returns (uint256 mintDelay_) {
        return SPOGRegistrarReader.getMintDelay(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function mintTTL() public view returns (uint256 mintTTL_) {
        return SPOGRegistrarReader.getMintTTL(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function minterFreezeTime() public view returns (uint256 minterFreezeTime_) {
        return SPOGRegistrarReader.getMinterFreezeTime(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function penaltyRate() public view returns (uint256 penaltyRate_) {
        return SPOGRegistrarReader.getPenaltyRate(spogRegistrar);
    }

    /// @inheritdoc IProtocol
    function rateModel() public view returns (address rateModel_) {
        return SPOGRegistrarReader.getMinterRateModel(spogRegistrar);
    }

    /******************************************************************************************************************\
    |                                          Internal Interactive Functions                                          |
    \******************************************************************************************************************/

    /**
     * @notice Imposes penalty on minter.
     * @dev penalty = penalty base * penalty rate
     * @param minter_ The address of the minter
     * @param penaltyBase_ The total penalization base
     */
    function _imposePenalty(address minter_, uint256 penaltyBase_) internal {
        uint256 penalty_ = (penaltyBase_ * penaltyRate()) / ONE;
        uint256 penaltyPrincipal_ = _getPrincipalValue(penalty_);

        // Calculate and add penalty principal to total minter's principal of active owed M
        _principalOfActiveOwedM[minter_] += penaltyPrincipal_;
        _totalPrincipalOfActiveOwedM += penaltyPrincipal_;

        emit PenaltyImposed(minter_, penalty_);
    }

    /**
     * @notice Imposes penalty if minter missed collateral updates.
     * @dev penalty = total active owed M * penalty rate * number of missed intervals
     * @param minter_ The address of the minter
     */
    function _imposePenaltyIfMissedCollateralUpdates(address minter_) internal {
        (uint256 penaltyBase_, uint256 penalizedUntil_) = _getPenaltyBaseAndTimeForMissedCollateralUpdates(minter_);

        if (penaltyBase_ == 0) return;

        // Save penalization interval to not double charge for the same missed periods again
        _penalizedUntilTimestamps[minter_] = penalizedUntil_;
        // We charged for the first missed interval based on previous collateral interval length only once
        // NOTE: extra caution for the case when SPOG changed collateral interval length
        _lastUpdateIntervals[minter_] = updateCollateralInterval();

        _imposePenalty(minter_, penaltyBase_);
    }

    /**
     * @notice Imposes penalty if minter is undercollateralized.
     * @dev penalty = excess active owed M * penalty rate
     * @param minter_ The address of the minter
     */
    function _imposePenaltyIfUndercollateralized(address minter_) internal {
        uint256 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);
        uint256 activeOwedM_ = activeOwedMOf(minter_);

        if (maxAllowedActiveOwedM_ >= activeOwedM_) return;

        _imposePenalty(minter_, activeOwedM_ - maxAllowedActiveOwedM_);
    }

    /**
     * @notice Repays active (not deactivated, not removed from SPOG) minter's owed M.
     * @param minter_ The address of the minter
     * @param maxAmount_ The maximum amount of active owed M to repay
     * @return amount_ The amount of active owed M that was actually repaid
     */
    function _repayForActiveMinter(address minter_, uint256 maxAmount_) internal returns (uint256 amount_) {
        amount_ = _min(activeOwedMOf(minter_), maxAmount_);
        uint256 principalAmount_ = _getPrincipalValue(amount_);

        _principalOfActiveOwedM[minter_] -= principalAmount_;
        _totalPrincipalOfActiveOwedM -= principalAmount_;
    }

    /**
     * @notice Repays inactive (deactivated, removed from SPOG) minter's owed M.
     * @param minter_ The address of the minter
     * @param maxAmount_ The maximum amount of inactive owed M to repay
     * @return amount_ The amount of inactive owed M that was actually repaid
     */
    function _repayForInactiveMinter(address minter_, uint256 maxAmount_) internal returns (uint256 amount_) {
        amount_ = _min(_inactiveOwedM[minter_], maxAmount_);

        _inactiveOwedM[minter_] -= amount_;
        _totalInactiveOwedM -= amount_;
    }

    /**
     * @notice Resolves the collateral retrieval IDs and updates the total pending collateral retrieval amount.
     * @param minter_ The address of the minter
     * @param retrievalIds_ The list of outstanding collateral retrieval IDs to resolve
     */
    function _resolvePendingRetrievals(address minter_, uint256[] calldata retrievalIds_) internal {
        for (uint256 index_; index_ < retrievalIds_.length; ++index_) {
            uint256 retrievalId_ = retrievalIds_[index_];

            _totalPendingCollateralRetrievals[minter_] -= _pendingCollateralRetrievals[minter_][retrievalId_];

            delete _pendingCollateralRetrievals[minter_][retrievalId_];
        }
    }

    /**
     * @notice Updates the collateral amount and update timestamp for the minter.
     * @param minter_ The address of the minter
     * @param amount_ The amount of collateral
     * @param newTimestamp_ The timestamp of the collateral update, minimum of all given validator timestamps
     */
    function _updateCollateral(address minter_, uint256 amount_, uint256 newTimestamp_) internal {
        uint256 lastCollateralUpdate_ = _lastCollateralUpdates[minter_];

        // Protocol already has more recent collateral update
        if (newTimestamp_ < lastCollateralUpdate_) revert StaleCollateralUpdate(newTimestamp_, lastCollateralUpdate_);

        _collaterals[minter_] = amount_;
        _lastCollateralUpdates[minter_] = newTimestamp_;
        // NOTE: Save for the future potential valid penalization if update collateral interval is changed by SPOG
        _lastUpdateIntervals[minter_] = updateCollateralInterval();
    }

    /******************************************************************************************************************\
    |                                           Internal View/Pure Functions                                           |
    \******************************************************************************************************************/

    /**
     * @notice Returns the penalization base and the penalized until timestamp.
     * @param minter_ The address of the minter
     * @return penaltyBase_ The base amount of penalty
     * @return penalizedUntil_ The timestamp until which minter is penalized for missed collateral updates
     */
    function _getPenaltyBaseAndTimeForMissedCollateralUpdates(
        address minter_
    ) internal view returns (uint256 penaltyBase_, uint256 penalizedUntil_) {
        uint256 updateInterval_ = _lastUpdateIntervals[minter_];
        uint256 lastUpdate_ = _lastCollateralUpdates[minter_];
        uint256 penalizeFrom_ = _max(lastUpdate_, _penalizedUntilTimestamps[minter_]);
        uint256 penalizationDeadline_ = penalizeFrom_ + updateInterval_;

        // Return if it is first update collateral ever or deadline for new penalization was not reached yet
        if (updateInterval_ == 0 || penalizationDeadline_ > block.timestamp) return (0, penalizeFrom_);

        uint256 missedIntervals_ = 1 + (block.timestamp - penalizationDeadline_) / updateCollateralInterval();

        penaltyBase_ = missedIntervals_ * activeOwedMOf(minter_);
        penalizedUntil_ = penalizeFrom_ + (missedIntervals_ * updateInterval_);
    }

    /**
     * @notice Returns the present value of M given the principal amount and the current index.
     * @dev present = pricipal * index
     * @param principalValue_ The principal value of M
     */
    function _getPresentValue(uint256 principalValue_) internal view returns (uint256 presentValue_) {
        return _getPresentAmount(principalValue_, currentIndex());
    }

    /**
     * @notice Returns the principal amount of M given the present value and the current index.
     * @dev present = principal * index
     * @param presentValue_ The present value of M
     */
    function _getPrincipalValue(uint256 presentValue_) internal view returns (uint256 principalValue_) {
        return _getPrincipalAmount(presentValue_, currentIndex());
    }

    /**
     * @notice Returns the EIP-712 digest for updateCollateral method
     * @param minter_ The address of the minter
     * @param collateral_ The amount of collateral
     * @param retrievalIds_ The list of outstanding collateral retrieval IDs to resolve
     * @param metadataHash_ The hash of metadata of the collateral update, reserved for future informational use
     * @param timestamp_ The timestamp of the collateral update
     */
    function _getUpdateCollateralDigest(
        address minter_,
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        uint256 timestamp_
    ) internal view returns (bytes32) {
        return
            _getDigest(
                keccak256(
                    abi.encode(
                        UPDATE_COLLATERAL_TYPEHASH,
                        minter_,
                        collateral_,
                        retrievalIds_,
                        metadataHash_,
                        timestamp_
                    )
                )
            );
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 max_) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 min_) {
        return a_ < b_ ? a_ : b_;
    }

    function _minIgnoreZero(uint256 a_, uint256 b_) internal pure returns (uint256 min_) {
        return a_ == 0 ? b_ : _min(a_, b_);
    }

    /**
     * @notice Returns the current rate from the rate model contract.
     */
    function _rate() internal view override returns (uint256 rate_) {
        (bool success_, bytes memory returnData_) = rateModel().staticcall(
            abi.encodeWithSelector(IRateModel.rate.selector)
        );

        rate_ = success_ ? abi.decode(returnData_, (uint256)) : 0;
    }

    /**
     * @notice Reverts if minter is frozen by validator.
     * @param minter_ The address of the minter
     */
    function _revertIfMinterFrozen(address minter_) internal view {
        if (block.timestamp < _unfrozenTimestamps[minter_]) revert FrozenMinter();
    }

    /**
     * @notice Reverts if minter is inactive.
     * @param minter_ The address of the minter
     */
    function _revertIfInactiveMinter(address minter_) internal view {
        if (!_isActiveMinter[minter_]) revert InactiveMinter();
    }

    /**
     * @notice Reverts if validator is not approved.
     * @param validator_ The address of the validator
     */
    function _revertIfNotApprovedValidator(address validator_) internal view {
        if (!isValidatorApprovedBySPOG(validator_)) revert NotApprovedValidator();
    }

    /**
     * @notice Reverts if minter position will be undercollateralized after changes.
     * @param minter_ The address of the minter
     * @param additionalOwedM_ The amount of additional owed M the action will add to minter's position
     */
    function _revertIfUndercollateralized(address minter_, uint256 additionalOwedM_) internal view {
        uint256 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);
        uint256 activeOwedM_ = activeOwedMOf(minter_);
        uint256 finalActiveOwedM_ = activeOwedM_ + additionalOwedM_;

        if (finalActiveOwedM_ > maxAllowedActiveOwedM_)
            revert Undercollateralized(finalActiveOwedM_, maxAllowedActiveOwedM_);
    }

    /**
     * @notice Checks that enough valid unique signatures were provided
     * @param minter_ The address of the minter
     * @param collateral_ The amount of collateral
     * @param retrievalIds_ The list of proposed collateral retrieval IDs to resolve
     * @param metadataHash_ The hash of metadata of the collateral update, reserved for future informational use
     * @param validators_ The list of validators
     * @param timestamps_ The list of validator timestamps for the collateral update signatures
     * @param signatures_ The list of signatures
     * @return minTimestamp_ The minimum timestamp across all valid timestamps with valid signatures
     */
    function _verifyValidatorSignatures(
        address minter_,
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        address[] calldata validators_,
        uint256[] calldata timestamps_,
        bytes[] calldata signatures_
    ) internal view returns (uint256 minTimestamp_) {
        uint256 threshold_ = updateCollateralValidatorThreshold();

        minTimestamp_ = block.timestamp;

        // Stop processing if there are no more signatures or `threshold_` is reached.
        for (uint256 index_; index_ < signatures_.length && threshold_ > 0; ++index_) {
            // Check that validator address is unique and not accounted for
            // NOTE: We revert here because this failure is entirely within the minter's control.
            if (index_ > 0 && validators_[index_] <= validators_[index_ - 1]) revert InvalidSignatureOrder();

            // Check that the timestamp is not in the future.
            if (timestamps_[index_] > block.timestamp) revert FutureTimestamp();

            bytes32 digest_ = _getUpdateCollateralDigest(
                minter_,
                collateral_,
                retrievalIds_,
                metadataHash_,
                timestamps_[index_]
            );

            // Check that validator is approved by SPOG.
            if (!isValidatorApprovedBySPOG(validators_[index_])) continue;

            // Check that ECDSA or ERC1271 signatures for given digest are valid.
            if (!SignatureChecker.isValidSignature(validators_[index_], digest_, signatures_[index_])) continue;

            // Find minimum between all valid timestamps for valid signatures
            minTimestamp_ = _minIgnoreZero(minTimestamp_, timestamps_[index_]);

            --threshold_;
        }

        // NOTE: Due to STACK_TOO_DEEP issues, we need to refetch `requiredThreshold_` and compute the number of valid
        //       signatures here, in order to emit the correct error message. However, the code will only reach this
        //       point to inevitably revert, so the gas cost is not much of a concern.
        uint256 requiredThreshold_ = updateCollateralValidatorThreshold();
        uint256 validSignatures_ = requiredThreshold_ - threshold_;

        if (threshold_ > 0) revert NotEnoughValidSignatures(validSignatures_, requiredThreshold_);
    }
}
