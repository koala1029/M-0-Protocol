// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { IContinuousIndexing } from "./interfaces/IContinuousIndexing.sol";

import { ContinuousIndexingMath } from "./libs/ContinuousIndexingMath.sol";

abstract contract ContinuousIndexing is IContinuousIndexing {
    uint128 internal _latestIndex;
    uint32 internal _latestRate;
    uint40 internal _latestUpdateTimestamp;

    constructor() {
        _latestIndex = uint128(1 * ContinuousIndexingMath.EXP_SCALED_ONE);
        _latestUpdateTimestamp = uint40(block.timestamp);
    }

    /******************************************************************************************************************\
    |                                      External/Public Interactive Functions                                       |
    \******************************************************************************************************************/

    function updateIndex() public virtual returns (uint128 currentIndex_) {
        // NOTE: `_rate()` can depend on `_latestIndex` and `_latestUpdateTimestamp`, so only update them after this.
        uint32 rate_ = _rate();

        if (_latestUpdateTimestamp == block.timestamp && _latestRate == rate_) return _latestIndex;

        // NOTE: `currentIndex()` depends on `_latestRate`, so only update it after this.
        _latestIndex = currentIndex_ = currentIndex();
        _latestRate = rate_;
        _latestUpdateTimestamp = uint40(block.timestamp);

        emit IndexUpdated(currentIndex_, rate_);
    }

    /******************************************************************************************************************\
    |                                       External/Public View/Pure Functions                                        |
    \******************************************************************************************************************/

    function currentIndex() public view virtual returns (uint128 currentIndex_) {
        return
            ContinuousIndexingMath.multiplyDown(
                _latestIndex,
                ContinuousIndexingMath.getContinuousIndex(
                    ContinuousIndexingMath.convertFromBasisPoints(_latestRate),
                    uint32(block.timestamp - _latestUpdateTimestamp)
                )
            );
    }

    function latestIndex() public view virtual returns (uint128 index_) {
        return _latestIndex;
    }

    function latestUpdateTimestamp() public view virtual returns (uint40 latestUpdateTimestamp_) {
        return _latestUpdateTimestamp;
    }

    /******************************************************************************************************************\
    |                                          Internal Interactive Functions                                          |
    \******************************************************************************************************************/

    function _getPresentAmountUpAndUpdateIndex(uint128 principalAmount_) internal returns (uint128 presentAmount_) {
        return _getPresentAmountUp(principalAmount_, updateIndex());
    }

    function _getPresentAmountDownAndUpdateIndex(uint128 principalAmount_) internal returns (uint128 presentAmount_) {
        return _getPresentAmountDown(principalAmount_, updateIndex());
    }

    function _getPrincipalAmountUpAndUpdateIndex(uint128 presentAmount_) internal returns (uint128 principalAmount_) {
        return _getPrincipalAmountUp(presentAmount_, updateIndex());
    }

    function _getPrincipalAmountDownAndUpdateIndex(uint128 presentAmount_) internal returns (uint128 principalAmount_) {
        return _getPrincipalAmountDown(presentAmount_, updateIndex());
    }

    /******************************************************************************************************************\
    |                                           Internal View/Pure Functions                                           |
    \******************************************************************************************************************/

    /**
     * @dev   Returns the present value given the principal value, using the current index.
     * @param principalAmount_ The principal value
     */
    function _getPresentAmountUp(uint128 principalAmount_) internal view returns (uint128 presentValue_) {
        return _getPresentAmountUp(principalAmount_, currentIndex());
    }

    /**
     * @dev   Returns the present value given the principal value, using the current index.
     * @param principalAmount_ The principal value
     */
    function _getPresentAmountDown(uint128 principalAmount_) internal view returns (uint128 presentValue_) {
        return _getPresentAmountDown(principalAmount_, currentIndex());
    }

    /**
     * @dev   Returns the present value given the principal value and an index.
     * @param principalAmount_ The principal value
     * @param index_           An index
     */
    function _getPresentAmountUp(
        uint128 principalAmount_,
        uint128 index_
    ) internal pure returns (uint128 presentAmount_) {
        return ContinuousIndexingMath.multiplyUp(principalAmount_, index_);
    }

    /**
     * @dev   Returns the present value given the principal value and an index.
     * @param principalAmount_ The principal value
     * @param index_           An index
     */
    function _getPresentAmountDown(
        uint128 principalAmount_,
        uint128 index_
    ) internal pure returns (uint128 presentAmount_) {
        return ContinuousIndexingMath.multiplyDown(principalAmount_, index_);
    }

    /**
     * @dev   Returns the principal value given the present value, using the current index.
     * @param presentAmount_ The present value
     */
    function _getPrincipalAmountUp(uint128 presentAmount_) internal view returns (uint128 principalValue_) {
        return _getPrincipalAmountUp(presentAmount_, currentIndex());
    }

    /**
     * @dev   Returns the principal value given the present value, using the current index.
     * @param presentAmount_ The present value
     */
    function _getPrincipalAmountDown(uint128 presentAmount_) internal view returns (uint128 principalValue_) {
        return _getPrincipalAmountDown(presentAmount_, currentIndex());
    }

    /**
     * @dev   Returns the principal value given the present value, using the current index.
     * @param presentAmount_ The present value
     * @param index_         An index
     */
    function _getPrincipalAmountUp(
        uint128 presentAmount_,
        uint128 index_
    ) internal pure returns (uint128 principalAmount_) {
        return ContinuousIndexingMath.divideUp(presentAmount_, index_);
    }

    /**
     * @dev   Returns the principal value given the present value, using the current index.
     * @param presentAmount_ The present value
     * @param index_         An index
     */
    function _getPrincipalAmountDown(
        uint128 presentAmount_,
        uint128 index_
    ) internal pure returns (uint128 principalAmount_) {
        return ContinuousIndexingMath.divideDown(presentAmount_, index_);
    }

    function _rate() internal view virtual returns (uint32 rate_);
}
