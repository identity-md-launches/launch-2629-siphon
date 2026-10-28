// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice An anchor that answers `getSlot0` with dirty bits above the uint160 price and the int24 tick.
contract DirtyAnchor {
    uint256 public immutable priceWord;
    uint256 public immutable tickWord;

    constructor(uint256 priceWord_, uint256 tickWord_) {
        priceWord = priceWord_;
        tickWord = tickWord_;
    }

    fallback() external {
        uint256 p = priceWord;
        uint256 t = tickWord;
        assembly {
            mstore(0, p)
            mstore(32, t)
            return(0, 64)
        }
    }
}

/// @notice An anchor that tries to write storage while answering, which a `staticcall` forbids.
contract StateWritingAnchor {
    uint256 public calls;

    function getSlot0(bytes32) external returns (uint160, int24, uint24, uint24) {
        calls++;
        return (1 << 96, 7, 0, 0);
    }
}

/// @notice An anchor that answers well-formed slot0 words followed by a large tail of returndata.
contract ReturnBombAnchor {
    fallback() external {
        assembly {
            mstore(0, 0x1000000000000000000000000)
            mstore(32, 42)
            return(0, 100000)
        }
    }
}

/// @notice An anchor that burns every unit of gas it is given (executes INVALID), as a pre-0.8 `assert`
/// failure or an out-of-gas loop would.
contract GasBurningAnchor {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

/// @notice An anchor that answers the pool id it was asked for back as the price (a view cannot record
/// it), so a test can see exactly which id the hook passed.
contract EchoAnchor {
    function getSlot0(bytes32 poolId) external pure returns (uint160, int24, uint24, uint24) {
        return (uint160(uint256(poolId)), int24(int256(uint256(poolId) % 1000)), 0, 0);
    }
}
