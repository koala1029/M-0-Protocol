// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { SignatureChecker } from "../lib/common/src/libs/SignatureChecker.sol";

import { ERC712 } from "../lib/common/src/ERC712.sol";

import { TTGRegistrarReader } from "./libs/TTGRegistrarReader.sol";
import { UIntMath } from "./libs/UIntMath.sol";

import { IContinuousIndexing } from "./interfaces/IContinuousIndexing.sol";
import { IMToken } from "./interfaces/IMToken.sol";
import { IMinterGateway } from "./interfaces/IMinterGateway.sol";
import { IRateModel } from "./interfaces/IRateModel.sol";

import { ContinuousIndexing } from "./abstract/ContinuousIndexing.sol";

// TODO: Revisit storage slot and struct ordering once accurate gas reporting is achieved.
// TODO: Consider `totalPendingCollateralRetrievalOf` or `totalCollateralPendingRetrievalOf`.
// TODO: Consider `totalResolvedCollateralRetrieval` or `totalCollateralRetrievalResolved`.

/**
 * @title MinterGateway
 * @author M^ZERO LABS_
 * @notice Minting Gateway of M Token for all approved by TTG and activated minters.
 */
contract MinterGateway is IMinterGateway, ContinuousIndexing, ERC712 {
    struct MintProposal {
        // 1st slot
        uint48 id;
        uint40 createdAt;
        address destination;
        // 2nd slot
        uint128 amount;
    }

    struct MinterState {
        // 1st slot
        uint128 collateral;
        uint128 totalPendingRetrievals;
        // 2nd slot
        uint32 lastUpdateInterval;
        uint40 updateTimestamp;
        uint40 penalizedUntilTimestamp;
        uint40 unfrozenTimestamp;
        bool isActive;
        bool isDeactivated;
    }

    struct OwedM {
        uint128 principalOfActive;
        uint128 inactive;
    }

    /******************************************************************************************************************\
    |                                                    Variables                                                     |
    \******************************************************************************************************************/

    /// @dev 100% in basis points.
    uint16 public constant ONE = 10_000;

    // keccak256("UpdateCollateral(address minter,uint256 collateral,uint256[] retrievalIds,bytes32 metadataHash,uint256 timestamp)")
    bytes32 public constant UPDATE_COLLATERAL_TYPEHASH =
        0x22b57ca54bd15c6234b29e87aa1d76a0841b6e65e63d7acacef989de0bc3ff9e;

    /// @inheritdoc IMinterGateway
    address public immutable ttgRegistrar;

    /// @inheritdoc IMinterGateway
    address public immutable ttgVault;

    /// @inheritdoc IMinterGateway
    address public immutable mToken;

    /// @dev Nonce used to generate unique mint proposal IDs.
    uint48 internal _mintNonce;

    /// @dev Nonce used to generate unique retrieval proposal IDs.
    uint48 internal _retrievalNonce;

    /// @dev The total principal amount of active M
    uint128 internal _totalPrincipalOfActiveOwedM;

    /// @dev The total amount of inactive M, sum of all inactive minter's owed M.
    uint128 internal _totalInactiveOwedM;

    /// @dev The state of each minter, their collaterals, relevant timestamps, and total pending retrievals.
    mapping(address minter => MinterState state) internal _minterStates;

    /// @dev The mint proposals of minter (mint ID, creation timestamp, destination, amount).
    mapping(address minter => MintProposal proposal) internal _mintProposals;

    /// @dev The owed M of active and inactive minters (principal of active, inactive).
    mapping(address minter => OwedM owedM) internal _owedM;

    /// @dev The pending collateral retrievals of minter (retrieval ID, amount).
    mapping(address minter => mapping(uint48 retrievalId => uint128 amount)) internal _pendingCollateralRetrievals;

    /******************************************************************************************************************\
    |                                            Modifiers and Constructor                                             |
    \******************************************************************************************************************/

    /// @notice Only allow active minter to call function.
    modifier onlyActiveMinter() {
        _revertIfInactiveMinter(msg.sender);

        _;
    }

    /// @notice Only allow approved validator in TTG to call function.
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
     * @param  ttgRegistrar_ The address of the TTG Registrar contract.
     * @param  mToken_        The address of the M Token.
     */
    constructor(address ttgRegistrar_, address mToken_) ContinuousIndexing() ERC712("MinterGateway") {
        if ((ttgRegistrar = ttgRegistrar_) == address(0)) revert ZeroTTGRegistrar();
        if ((ttgVault = TTGRegistrarReader.getVault(ttgRegistrar_)) == address(0)) revert ZeroTTGVault();
        if ((mToken = mToken_) == address(0)) revert ZeroMToken();
    }

    /******************************************************************************************************************\
    |                                          External Interactive Functions                                          |
    \******************************************************************************************************************/

    /// @inheritdoc IMinterGateway
    function updateCollateral(
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        address[] calldata validators_,
        uint256[] calldata timestamps_,
        bytes[] calldata signatures_
    ) external onlyActiveMinter returns (uint40 minTimestamp_) {
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

        uint128 safeCollateral_ = UIntMath.safe128(collateral_);

        // TODO: Consider adding the `totalResolvedRetrievals_` to the event.
        emit CollateralUpdated(msg.sender, safeCollateral_, retrievalIds_, metadataHash_, minTimestamp_);

        _resolvePendingRetrievals(msg.sender, retrievalIds_);

        uint32 updateCollateralInterval_ = updateCollateralInterval();

        _imposePenaltyIfMissedCollateralUpdates(msg.sender, updateCollateralInterval_);

        _updateCollateral(msg.sender, safeCollateral_, minTimestamp_);

        // NOTE: If non-zero, save `updateCollateralInterval_` for fair missed interval calculation if TTG changes it.
        if (updateCollateralInterval_ != 0) {
            _minterStates[msg.sender].lastUpdateInterval = updateCollateralInterval_;
        }

        _imposePenaltyIfUndercollateralized(msg.sender);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function proposeRetrieval(uint256 collateral_) external onlyActiveMinter returns (uint48 retrievalId_) {
        unchecked {
            retrievalId_ = ++_retrievalNonce;
        }

        MinterState storage minterState_ = _minterStates[msg.sender];
        uint128 currentCollateral_ = minterState_.collateral;
        uint128 safeRetrieval_ = UIntMath.safe128(collateral_);
        uint128 updatedTotalPendingRetrievals_ = minterState_.totalPendingRetrievals + safeRetrieval_;

        // NOTE: Revert if collateral is less than sum of all pending retrievals even if there is no owed M by minter.
        if (currentCollateral_ < updatedTotalPendingRetrievals_) {
            revert RetrievalsExceedCollateral(updatedTotalPendingRetrievals_, currentCollateral_);
        }

        minterState_.totalPendingRetrievals = updatedTotalPendingRetrievals_;
        _pendingCollateralRetrievals[msg.sender][retrievalId_] = safeRetrieval_;

        _revertIfUndercollateralized(msg.sender, 0);

        emit RetrievalCreated(retrievalId_, msg.sender, safeRetrieval_);
    }

    /// @inheritdoc IMinterGateway
    function proposeMint(
        uint256 amount_,
        address destination_
    ) external onlyActiveMinter onlyUnfrozenMinter returns (uint48 mintId_) {
        uint128 safeAmount_ = UIntMath.safe128(amount_);

        _revertIfUndercollateralized(msg.sender, safeAmount_); // Ensure minter remains sufficiently collateralized.

        unchecked {
            mintId_ = ++_mintNonce;
        }

        _mintProposals[msg.sender] = MintProposal(mintId_, uint40(block.timestamp), destination_, safeAmount_);

        emit MintProposed(mintId_, msg.sender, safeAmount_, destination_);
    }

    /// @inheritdoc IMinterGateway
    function mintM(uint256 mintId_) external onlyActiveMinter onlyUnfrozenMinter {
        MintProposal storage mintProposal_ = _mintProposals[msg.sender];

        (uint48 id_, uint40 createdAt_, address destination_, uint128 amount_) = (
            mintProposal_.id,
            mintProposal_.createdAt,
            mintProposal_.destination,
            mintProposal_.amount
        );

        if (id_ != mintId_) revert InvalidMintProposal();

        // Check that mint proposal is executable.
        uint40 activeAt_ = createdAt_ + mintDelay();
        if (block.timestamp < activeAt_) revert PendingMintProposal(activeAt_);

        uint40 expiresAt_ = activeAt_ + mintTTL();
        if (block.timestamp > expiresAt_) revert ExpiredMintProposal(expiresAt_);

        _revertIfUndercollateralized(msg.sender, amount_); // Ensure minter remains sufficiently collateralized.

        delete _mintProposals[msg.sender]; // Delete mint request.

        emit MintExecuted(id_);

        // Adjust principal of active owed M for minter.
        // NOTE: When minting a present amount, round the principal up in favor of the Minter Gateway.
        uint128 principalAmount_ = _getPrincipalAmountRoundedUp(amount_);
        _totalPrincipalOfActiveOwedM += principalAmount_;

        // NOTE: unchecked is used here since `_totalPrincipalOfActiveOwedM` would overflow first.
        unchecked {
            _owedM[msg.sender].principalOfActive += principalAmount_;
        }

        IMToken(mToken).mint(destination_, amount_);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the mint
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function burnM(address minter_, uint256 maxAmount_) external {
        uint32 updateCollateralInterval_ = updateCollateralInterval();

        // NOTE: Penalize only for missed collateral updates, not for undercollateralization.
        // Undercollateralization within one update interval is forgiven.
        _imposePenaltyIfMissedCollateralUpdates(minter_, updateCollateralInterval_);

        // NOTE: If non-zero, save `updateCollateralInterval_` for fair missed interval calculation if TTG changes it.
        if (updateCollateralInterval_ != 0) {
            _minterStates[minter_].lastUpdateInterval = updateCollateralInterval_;
        }

        uint128 amount_ = _minterStates[minter_].isActive
            ? _repayForActiveMinter(minter_, UIntMath.safe128(maxAmount_))
            : _repayForInactiveMinter(minter_, UIntMath.safe128(maxAmount_));

        emit BurnExecuted(minter_, amount_, msg.sender);

        IMToken(mToken).burn(msg.sender, amount_); // Burn actual M tokens

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the burn
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function cancelMint(address minter_, uint256 mintId_) external onlyApprovedValidator {
        // TODO: Possible gas optimization by getting storage pointer once and using it again for delete.
        uint48 id_ = _mintProposals[minter_].id;

        if (id_ != mintId_) revert InvalidMintProposal();

        delete _mintProposals[minter_];

        emit MintCanceled(id_, msg.sender);
    }

    /// @inheritdoc IMinterGateway
    function freezeMinter(address minter_) external onlyApprovedValidator returns (uint40 frozenUntil_) {
        _revertIfInactiveMinter(minter_);

        _minterStates[minter_].unfrozenTimestamp = frozenUntil_ = uint40(block.timestamp) + minterFreezeTime();

        emit MinterFrozen(minter_, frozenUntil_);
    }

    /// @inheritdoc IMinterGateway
    function activateMinter(address minter_) external {
        if (!isMinterApprovedByTTG(minter_)) revert NotApprovedMinter();
        if (_minterStates[minter_].isDeactivated) revert DeactivatedMinter();

        _minterStates[minter_].isActive = true;

        emit MinterActivated(minter_, msg.sender);
    }

    /// @inheritdoc IMinterGateway
    function deactivateMinter(address minter_) external returns (uint128 inactiveOwedM_) {
        if (isMinterApprovedByTTG(minter_)) revert StillApprovedMinter();

        _revertIfInactiveMinter(minter_);

        // NOTE: Instead of imposing, calculate penalty and add it to `_inactiveOwedM` to save gas.
        inactiveOwedM_ = activeOwedMOf(minter_) + getPenaltyForMissedCollateralUpdates(minter_);

        emit MinterDeactivated(minter_, inactiveOwedM_, msg.sender);

        // NOTE: Unchecked can be used here.
        //       If `_totalInactiveOwedM` overflows, the protocol would be in a broken state.
        //       Minters could no longer be deactivated.
        unchecked {
            _totalInactiveOwedM += inactiveOwedM_;
            _owedM[minter_].inactive += inactiveOwedM_;
        }

        // Adjust total principal of owed M.
        _totalPrincipalOfActiveOwedM -= _owedM[minter_].principalOfActive;

        // Reset reasonable aspects of minter's state.
        delete _minterStates[minter_];
        delete _mintProposals[minter_];
        delete _owedM[minter_].principalOfActive;

        _minterStates[minter_].isDeactivated = true;

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the
        //       deactivation can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IContinuousIndexing
    function updateIndex() public override(IContinuousIndexing, ContinuousIndexing) returns (uint128 index_) {
        // NOTE: Since the currentIndex of the Minter Gateway and mToken are constant thought this context's execution (since
        //       the block.timestamp is not changing) we can compute excessOwedM without updating the mToken index.
        uint128 excessOwedM_ = excessOwedM();

        if (excessOwedM_ > 0) IMToken(mToken).mint(ttgVault, excessOwedM_); // Mint M to TTG Vault.

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        // NOTE: With the current rate models, the minter rate does not depend on anything in the Minter Gateway or mToken, so
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

    /// @inheritdoc IMinterGateway
    function totalActiveOwedM() public view returns (uint128) {
        return _getPresentAmount(_totalPrincipalOfActiveOwedM);
    }

    /// @inheritdoc IMinterGateway
    function totalInactiveOwedM() public view returns (uint128) {
        return _totalInactiveOwedM;
    }

    /// @inheritdoc IMinterGateway
    function totalOwedM() public view returns (uint128) {
        return totalActiveOwedM() + totalInactiveOwedM();
    }

    /// @inheritdoc IMinterGateway
    function excessOwedM() public view returns (uint128 excessOwedM_) {
        // TODO: Consider dropping this safe cast since if the total M supply is greater than 2^128, there are bigger
        //       issues, but also because reverts here bricks `updateIndex()`, which bricks everything else.
        uint128 totalMSupply_ = UIntMath.safe128(IMToken(mToken).totalSupply());
        uint128 totalOwedM_ = totalOwedM();

        unchecked {
            if (totalOwedM_ > totalMSupply_) {
                return totalOwedM_ - totalMSupply_;
            }
        }
    }

    /// @inheritdoc IMinterGateway
    function minterRate() external view returns (uint32) {
        return _latestRate;
    }

    /// @inheritdoc IMinterGateway
    function isActiveMinter(address minter_) external view returns (bool) {
        return _minterStates[minter_].isActive;
    }

    /// @inheritdoc IMinterGateway
    function isDeactivatedMinter(address minter_) external view returns (bool) {
        return _minterStates[minter_].isDeactivated;
    }

    /// @inheritdoc IMinterGateway
    function activeOwedMOf(address minter_) public view returns (uint128) {
        // TODO: This should also include the present value of unavoidable penalities. But then it would be very, if not
        //       impossible, to determine the `totalActiveOwedM` to the same standards. Perhaps we need a `penaltiesOf`
        //       external function to provide the present value of unavoidable penalities.
        return _getPresentAmount(_owedM[minter_].principalOfActive);
    }

    /// @inheritdoc IMinterGateway
    function maxAllowedActiveOwedMOf(address minter_) public view returns (uint128) {
        return (collateralOf(minter_) * mintRatio()) / ONE;
    }

    /// @inheritdoc IMinterGateway
    function inactiveOwedMOf(address minter_) external view returns (uint128) {
        return _owedM[minter_].inactive;
    }

    /// @inheritdoc IMinterGateway
    function collateralOf(address minter_) public view returns (uint128) {
        // If collateral was not updated before deadline, assume that minter's collateral is zero.
        return
            block.timestamp < collateralUpdateDeadlineOf(minter_)
                ? _minterStates[minter_].collateral - _minterStates[minter_].totalPendingRetrievals
                : 0;
    }

    /// @inheritdoc IMinterGateway
    function collateralUpdateOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].updateTimestamp;
    }

    /// @inheritdoc IMinterGateway
    function collateralUpdateDeadlineOf(address minter_) public view returns (uint40) {
        return _minterStates[minter_].updateTimestamp + _minterStates[minter_].lastUpdateInterval;
    }

    /// @inheritdoc IMinterGateway
    function lastCollateralUpdateIntervalOf(address minter_) external view returns (uint32) {
        return _minterStates[minter_].lastUpdateInterval;
    }

    /// @inheritdoc IMinterGateway
    function penalizedUntilOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].penalizedUntilTimestamp;
    }

    /// @inheritdoc IMinterGateway
    function getPenaltyForMissedCollateralUpdates(address minter_) public view returns (uint128) {
        (uint128 penaltyBase_, ) = _getPenaltyBaseAndTimeForMissedCollateralUpdates(
            minter_,
            updateCollateralInterval()
        );

        return (penaltyBase_ * penaltyRate()) / ONE;
    }

    /// @inheritdoc IMinterGateway
    function mintProposalOf(
        address minter_
    ) external view returns (uint48 mintId_, uint40 createdAt_, address destination_, uint128 amount_) {
        mintId_ = _mintProposals[minter_].id;
        createdAt_ = _mintProposals[minter_].createdAt;
        destination_ = _mintProposals[minter_].destination;
        amount_ = _mintProposals[minter_].amount;
    }

    /// @inheritdoc IMinterGateway
    function pendingCollateralRetrievalOf(address minter_, uint256 retrievalId_) external view returns (uint128) {
        return _pendingCollateralRetrievals[minter_][UIntMath.safe48(retrievalId_)];
    }

    /// @inheritdoc IMinterGateway
    function totalPendingCollateralRetrievalsOf(address minter_) external view returns (uint128) {
        return _minterStates[minter_].totalPendingRetrievals;
    }

    /// @inheritdoc IMinterGateway
    function unfrozenTimeOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].unfrozenTimestamp;
    }

    /******************************************************************************************************************\
    |                                       TTG Registrar Reader Functions                                            |
    \******************************************************************************************************************/

    /// @inheritdoc IMinterGateway
    function isMinterApprovedByTTG(address minter_) public view returns (bool) {
        return TTGRegistrarReader.isApprovedMinter(ttgRegistrar, minter_);
    }

    /// @inheritdoc IMinterGateway
    function isValidatorApprovedByTTG(address validator_) public view returns (bool) {
        return TTGRegistrarReader.isApprovedValidator(ttgRegistrar, validator_);
    }

    /// @inheritdoc IMinterGateway
    function updateCollateralInterval() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getUpdateCollateralInterval(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function updateCollateralValidatorThreshold() public view returns (uint256) {
        return TTGRegistrarReader.getUpdateCollateralValidatorThreshold(ttgRegistrar);
    }

    /// @inheritdoc IMinterGateway
    function mintRatio() public view returns (uint32) {
        // NOTE: It is possible for the mint ratio to be greater than 100%.
        return UIntMath.bound32(TTGRegistrarReader.getMintRatio(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function mintDelay() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMintDelay(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function mintTTL() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMintTTL(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function minterFreezeTime() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMinterFreezeTime(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function penaltyRate() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getPenaltyRate(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function rateModel() public view returns (address) {
        return TTGRegistrarReader.getMinterRateModel(ttgRegistrar);
    }

    /******************************************************************************************************************\
    |                                          Internal Interactive Functions                                          |
    \******************************************************************************************************************/

    /**
     * @dev   Imposes penalty on minter.
     * @dev   penalty = penalty base * penalty rate
     * @param minter_      The address of the minter
     * @param penaltyBase_ The total penalization base
     */
    function _imposePenalty(address minter_, uint128 penaltyBase_) internal {
        uint128 penalty_ = uint128((penaltyBase_ * penaltyRate()) / ONE);

        // NOTE: When imposing a present amount penalty, round the principal up in favor of the Minter Gateway.
        uint128 penaltyPrincipal_ = _getPrincipalAmountRoundedUp(penalty_);

        // NOTE: Unchecked can be used here.
        //       If `_totalPrincipalOfActiveOwedM` overflows, the protocol would be in a broken state.
        //       Minters could no longer be penalized and update their collateral.
        unchecked {
            // Calculate and add penalty principal to total minter's principal of active owed M
            _totalPrincipalOfActiveOwedM += penaltyPrincipal_;
            _owedM[minter_].principalOfActive += penaltyPrincipal_;
        }

        emit PenaltyImposed(minter_, penalty_);
    }

    /**
     * @dev   Imposes penalty if minter missed collateral updates.
     * @dev   penalty = total active owed M * penalty rate * number of missed intervals
     * @param minter_                   The address of the minter
     * @param updateCollateralInterval_ The current update collateral interval
     */
    function _imposePenaltyIfMissedCollateralUpdates(address minter_, uint32 updateCollateralInterval_) internal {
        (uint128 penaltyBase_, uint40 penalizedUntil_) = _getPenaltyBaseAndTimeForMissedCollateralUpdates(
            minter_,
            updateCollateralInterval_
        );

        if (penaltyBase_ == 0) return;

        // Save penalization interval to not double charge for the same missed periods again
        _minterStates[minter_].penalizedUntilTimestamp = penalizedUntil_;

        _imposePenalty(minter_, penaltyBase_);
    }

    /**
     * @dev   Imposes penalty if minter is undercollateralized.
     * @dev   penalty = excess active owed M * penalty rate
     * @param minter_ The address of the minter
     */
    function _imposePenaltyIfUndercollateralized(address minter_) internal {
        uint128 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);
        uint128 activeOwedM_ = activeOwedMOf(minter_);

        if (maxAllowedActiveOwedM_ >= activeOwedM_) return;

        // NOTE: unchecked is used here since `activeOwedM_`is greater than or equal to `maxAllowedActiveOwedM_`.
        unchecked {
            _imposePenalty(minter_, activeOwedM_ - maxAllowedActiveOwedM_);
        }
    }

    /**
     * @dev    Repays active (not deactivated, not removed from TTG) minter's owed M.
     * @param  minter_    The address of the minter
     * @param  maxAmount_ The maximum amount of active owed M to repay
     * @return amount_    The amount of active owed M that was actually repaid
     */
    function _repayForActiveMinter(address minter_, uint128 maxAmount_) internal returns (uint128 amount_) {
        amount_ = UIntMath.min128(activeOwedMOf(minter_), maxAmount_);

        // NOTE: When subtracting a present amount, round the principal down in favor of the Minter Gateway.
        uint128 principalAmount_ = _getPrincipalAmountRoundedDown(amount_);

        // NOTE: Unchecked can be used here.
        //       If `_owedM[minter_].principalOfActive` underflows, the protocol would be in a broken state.
        //       Minters could no longer repay.
        unchecked {
            _owedM[minter_].principalOfActive -= principalAmount_;
            _totalPrincipalOfActiveOwedM -= principalAmount_;
        }
    }

    /**
     * @dev    Repays inactive (deactivated, removed from TTG) minter's owed M.
     * @param  minter_    The address of the minter
     * @param  maxAmount_ The maximum amount of inactive owed M to repay
     * @return amount_    The amount of inactive owed M that was actually repaid
     */
    function _repayForInactiveMinter(address minter_, uint128 maxAmount_) internal returns (uint128 amount_) {
        amount_ = UIntMath.min128(_owedM[minter_].inactive, maxAmount_);

        // NOTE: Unchecked can be used here.
        //       If `_owedM[minter_].inactive` underflows, the protocol would be in a broken state.
        //       Minters could no longer repay.
        unchecked {
            _owedM[minter_].inactive -= amount_;
            _totalInactiveOwedM -= amount_;
        }
    }

    /**
     * @dev   Resolves the collateral retrieval IDs and updates the total pending collateral retrieval amount.
     * @param minter_       The address of the minter
     * @param retrievalIds_ The list of outstanding collateral retrieval IDs to resolve
     */
    function _resolvePendingRetrievals(
        address minter_,
        uint256[] calldata retrievalIds_
    ) internal returns (uint128 totalResolvedRetrievals_) {
        for (uint256 index_; index_ < retrievalIds_.length; ++index_) {
            uint48 retrievalId_ = UIntMath.safe48(retrievalIds_[index_]);

            totalResolvedRetrievals_ += _pendingCollateralRetrievals[minter_][retrievalId_];

            delete _pendingCollateralRetrievals[minter_][retrievalId_];
        }

        _minterStates[minter_].totalPendingRetrievals -= totalResolvedRetrievals_;
    }

    /**
     * @dev   Updates the collateral amount and update timestamp for the minter.
     * @param minter_       The address of the minter
     * @param amount_       The amount of collateral
     * @param newTimestamp_ The timestamp of the collateral update
     */
    function _updateCollateral(address minter_, uint128 amount_, uint40 newTimestamp_) internal {
        uint40 lastUpdateTimestamp_ = _minterStates[minter_].updateTimestamp;

        // MinterGateway already has more recent collateral update
        if (newTimestamp_ < lastUpdateTimestamp_) revert StaleCollateralUpdate(newTimestamp_, lastUpdateTimestamp_);

        _minterStates[minter_].collateral = amount_;
        _minterStates[minter_].updateTimestamp = newTimestamp_;
    }

    /******************************************************************************************************************\
    |                                           Internal View/Pure Functions                                           |
    \******************************************************************************************************************/

    /**
     * @dev    Returns the penalization base and the penalized until timestamp.
     * @param  minter_                   The address of the minter
     * @param  updateCollateralInterval_ The current update collateral interval
     * @return penaltyBase_              The base amount of penalty
     * @return penalizedUntil_           The timestamp until which minter is penalized for missed collateral updates
     */
    function _getPenaltyBaseAndTimeForMissedCollateralUpdates(
        address minter_,
        uint32 updateCollateralInterval_
    ) internal view returns (uint128 penaltyBase_, uint40 penalizedUntil_) {
        MinterState storage minterState_ = _minterStates[minter_];
        (uint32 lastUpdateInterval_, uint40 lastUpdate_, uint40 lastPenalizedUntil_) = (
            minterState_.lastUpdateInterval,
            minterState_.updateTimestamp,
            minterState_.penalizedUntilTimestamp
        );

        uint40 penalizeFrom_ = UIntMath.max40(lastUpdate_, lastPenalizedUntil_);
        uint40 penalizationDeadline_ = penalizeFrom_ + lastUpdateInterval_;

        // Return if it is first update collateral ever or deadline for new penalization was not reached yet
        if (lastUpdateInterval_ == 0 || penalizationDeadline_ > block.timestamp) return (0, penalizationDeadline_);

        // If `updateCollateralInterval_` is 0, then there is no missed interval charge at all.
        if (updateCollateralInterval_ == 0) return (0, penalizationDeadline_);

        // We charge for the first missed interval based on previous collateral interval length only once
        uint40 missedIntervals_;

        // NOTE: Unchecked can be used here.
        //       If `penaltyBase_` or `penalizedUntil_` overflows, the protocol would be in a broken state.
        //       Minters could no longer be penalized.
        unchecked {
            missedIntervals_ = 1 + (uint40(block.timestamp) - penalizationDeadline_) / updateCollateralInterval_;
            penaltyBase_ = missedIntervals_ * activeOwedMOf(minter_);
            penalizedUntil_ = penalizationDeadline_ + ((missedIntervals_ - 1) * updateCollateralInterval_);
        }
    }

    /**
     * @dev   Returns the present amount (rounded up) given the principal amount, using the current index.
     *        All present amounts are rounded up in favor of the Minter Gateway, since they are owed.
     * @param principalAmount_ The principal amount
     */
    function _getPresentAmount(uint128 principalAmount_) internal view returns (uint128) {
        return _getPresentAmountRoundedUp(principalAmount_, currentIndex());
    }

    /**
     * @dev   Returns the EIP-712 digest for updateCollateral method
     * @param minter_       The address of the minter
     * @param collateral_   The amount of collateral
     * @param retrievalIds_ The list of outstanding collateral retrieval IDs to resolve
     * @param metadataHash_ The hash of metadata of the collateral update, reserved for future informational use
     * @param timestamp_    The timestamp of the collateral update
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

    /**
     * @dev Returns the current rate from the rate model contract.
     */
    function _rate() internal view override returns (uint32 rate_) {
        (bool success_, bytes memory returnData_) = rateModel().staticcall(
            abi.encodeWithSelector(IRateModel.rate.selector)
        );

        rate_ = (success_ && returnData_.length >= 32) ? UIntMath.bound32(abi.decode(returnData_, (uint256))) : 0;
    }

    /**
     * @dev   Reverts if minter is frozen by validator.
     * @param minter_ The address of the minter
     */
    function _revertIfMinterFrozen(address minter_) internal view {
        if (block.timestamp < _minterStates[minter_].unfrozenTimestamp) revert FrozenMinter();
    }

    /**
     * @dev   Reverts if minter is inactive.
     * @param minter_ The address of the minter
     */
    function _revertIfInactiveMinter(address minter_) internal view {
        if (!_minterStates[minter_].isActive) revert InactiveMinter();
    }

    /**
     * @dev   Reverts if validator is not approved.
     * @param validator_ The address of the validator
     */
    function _revertIfNotApprovedValidator(address validator_) internal view {
        if (!isValidatorApprovedByTTG(validator_)) revert NotApprovedValidator();
    }

    /**
     * @dev   Reverts if minter position will be undercollateralized after changes.
     * @param minter_          The address of the minter
     * @param additionalOwedM_ The amount of additional owed M the action will add to minter's position
     */
    function _revertIfUndercollateralized(address minter_, uint128 additionalOwedM_) internal view {
        uint128 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);
        uint128 activeOwedM_ = activeOwedMOf(minter_);
        uint128 finalActiveOwedM_ = activeOwedM_ + additionalOwedM_;

        if (finalActiveOwedM_ > maxAllowedActiveOwedM_)
            revert Undercollateralized(finalActiveOwedM_, maxAllowedActiveOwedM_);
    }

    /**
     * @dev    Checks that enough valid unique signatures were provided
     * @param  minter_       The address of the minter
     * @param  collateral_   The amount of collateral
     * @param  retrievalIds_ The list of proposed collateral retrieval IDs to resolve
     * @param  metadataHash_ The hash of metadata of the collateral update, reserved for future informational use
     * @param  validators_   The list of validators
     * @param  timestamps_   The list of validator timestamps for the collateral update signatures
     * @param  signatures_   The list of signatures
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
    ) internal view returns (uint40 minTimestamp_) {
        uint256 threshold_ = updateCollateralValidatorThreshold();

        minTimestamp_ = uint40(block.timestamp);

        // Stop processing if there are no more signatures or `threshold_` is reached.
        for (uint256 index_; index_ < signatures_.length && threshold_ > 0; ++index_) {
            // Check that validator address is unique and not accounted for
            // NOTE: We revert here because this failure is entirely within the minter's control.
            if (index_ > 0 && validators_[index_] <= validators_[index_ - 1]) revert InvalidSignatureOrder();

            // Check that the timestamp is not in the future.
            if (timestamps_[index_] > uint40(block.timestamp)) revert FutureTimestamp();

            // NOTE: Need to store the variable here to avoid a stack too deep error.
            bytes32 digest_ = _getUpdateCollateralDigest(
                minter_,
                collateral_,
                retrievalIds_,
                metadataHash_,
                timestamps_[index_]
            );

            // Check that validator is approved by TTG.
            if (!isValidatorApprovedByTTG(validators_[index_])) continue;

            // Check that ECDSA or ERC1271 signatures for given digest are valid.
            if (!SignatureChecker.isValidSignature(validators_[index_], digest_, signatures_[index_])) continue;

            // Find minimum between all valid timestamps for valid signatures.
            minTimestamp_ = UIntMath.min40IgnoreZero(minTimestamp_, UIntMath.safe40(timestamps_[index_]));

            --threshold_;
        }

        // NOTE: Due to STACK_TOO_DEEP issues, we need to refetch `requiredThreshold_` and compute the number of valid
        //       signatures here, in order to emit the correct error message. However, the code will only reach this
        //       point to inevitably revert, so the gas cost is not much of a concern.
        if (threshold_ > 0) {
            uint256 requiredThreshold_ = updateCollateralValidatorThreshold();
            revert NotEnoughValidSignatures(requiredThreshold_ - threshold_, requiredThreshold_);
        }
    }
}
