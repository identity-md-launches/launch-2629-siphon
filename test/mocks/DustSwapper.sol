// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Swaps with a price limit and settles nothing: in a pool with no liquidity the swap only
/// moves the price, so the delta is zero and no token is paid.
contract DustSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) external {
        manager.unlock(abi.encode(key, zeroForOne, amountSpecified, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) =
            abi.decode(data, (PoolKey, bool, int256, uint160));
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        require(d.amount0() == 0 && d.amount1() == 0, "unexpected delta");
        return "";
    }
}
