// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice The slice of Uniswap's `StateView` the hook reads: `getSlot0(bytes32)`, selector 0xc815641c.
contract AnchorView {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(poolId);
    }
}

/// @notice An anchor whose `getSlot0` always reverts.
contract RevertingAnchor {
    function getSlot0(bytes32) external pure returns (uint160, int24, uint24, uint24) {
        revert("anchor down");
    }
}

/// @notice An anchor that answers with fixed values and records the id it was asked for.
contract FixedAnchor {
    uint160 public sqrtPrice;
    int24 public tick;
    bytes32 public lastPoolId;

    constructor(uint160 sqrtPrice_, int24 tick_) {
        sqrtPrice = sqrtPrice_;
        tick = tick_;
    }

    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        poolId; // a view cannot record it; tests pass the id through the hook's getter instead
        return (sqrtPrice, tick, 0, 12_500);
    }
}

/// @notice An anchor that answers with one word only: too short to be a slot0.
contract ShortAnchor {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @notice An anchor that halts exceptionally, consuming every unit of gas it is given.
contract GasBurningAnchor {
    fallback() external {
        assembly {
            invalid()
        }
    }
}
