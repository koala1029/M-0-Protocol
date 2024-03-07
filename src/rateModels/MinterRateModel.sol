// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { TTGRegistrarReader } from "../libs/TTGRegistrarReader.sol";

import { IRateModel } from "../interfaces/IRateModel.sol";
import { IMinterRateModel } from "./interfaces/IMinterRateModel.sol";

/**
 * @title  Minter Rate Model contract set in TTG (Two Token Governance) Registrar and accessed by Minter Gateway.
 * @author M^0 Labs
 */
contract MinterRateModel is IMinterRateModel {
    /* ============ Variables ============ */

    /// @inheritdoc IMinterRateModel
    address public immutable ttgRegistrar;

    /* ============ Constructor ============ */

    /**
     * @notice Constructs the MinterRateModel contract.
     * @param ttgRegistrar_ The address of the TTG Registrar contract.
     */
    constructor(address ttgRegistrar_) {
        if ((ttgRegistrar = ttgRegistrar_) == address(0)) revert ZeroTTGRegistrar();
    }

    /* ============ View/Pure Functions ============ */

    /// @inheritdoc IRateModel
    function rate() external view returns (uint256 rate_) {
        return baseRate();
    }

    /// @inheritdoc IMinterRateModel
    function baseRate() public view returns (uint256 baseRate_) {
        return TTGRegistrarReader.getBaseMinterRate(ttgRegistrar);
    }
}
