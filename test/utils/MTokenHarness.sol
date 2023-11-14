// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.21;

import { MToken } from "../../src/MToken.sol";

contract MTokenHarness is MToken {
    constructor(address protocol_, address spogRegistrar_) MToken(protocol_, spogRegistrar_) {}

    function setLatestIndex(uint256 index_) external {
        _latestIndex = index_;
    }

    function setLatestUpdated(uint256 timestamp_) external {
        _latestAccrualTime = timestamp_;
    }

    function setIsEarning(address account_, bool isEarning_) external {
        _isEarning[account_] = isEarning_;
    }

    function setHasOptedOut(address account_, bool hasOptedOut_) external {
        _hasOptedOutOfEarning[account_] = hasOptedOut_;
    }

    function setInternalTotalSupply(uint256 totalSupply_) external {
        _totalSupply = totalSupply_;
    }

    function setTotalEarningSupplyPrincipal(uint256 totalEarningSupplyPrincipal_) external {
        _totalEarningSupplyPrincipal = totalEarningSupplyPrincipal_;
    }

    function setInternalBalanceOf(address account_, uint256 balance_) external {
        _balances[account_] = balance_;
    }

    function internalBalanceOf(address account_) external view returns (uint256 balance_) {
        return _balances[account_];
    }

    function totalEarningSupplyPrincipal() external view returns (uint256 totalSupply_) {
        return _totalEarningSupplyPrincipal;
    }

    function internalTotalSupply() external view returns (uint256 totalSupply_) {
        return _totalSupply;
    }
}
