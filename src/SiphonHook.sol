// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title SiphonHook
/// @notice An observe-only Uniswap v4 hook. On every swap it reads its own pool's state, optionally
/// reads an owner-set anchor pool through `getSlot0(bytes32)` (selector 0xc815641c), and emits one
/// `PoolData` event. It takes no fee, returns no delta, keeps nothing in transient storage and never
/// moves a token.
/// @dev Hand-rolled rather than inheriting a base hook so the runtime stays under 2 KB. Only the two
/// callbacks the address advertises exist: `beforeInitialize` (required for a launch, so nobody can
/// open the pool before the hook has code) and `afterSwap`.
contract SiphonHook {
    using StateLibrary for IPoolManager;

    /// @notice The pool manager that drives the callbacks.
    IPoolManager public immutable poolManager;

    /// @notice The administrator: sets the anchor, pauses emission, hands ownership on.
    address public owner;
    /// @notice While true, `afterSwap` emits nothing and reads nothing; swaps still execute.
    bool public paused;
    /// @notice Contract answering `getSlot0(bytes32)` for the anchor pool, or zero while unset.
    address public anchor;
    /// @notice The anchor pool's id, passed to `getSlot0`.
    bytes32 public anchorPoolId;

    /// @notice One record per swap in a pool using this hook.
    /// @param blockNumber `block.number` at the swap. On Arbitrum Nitro chains such as Robinhood
    /// Chain this is the L1 block number the sequencer observed, not the L2 block.
    /// @param sqrtPriceSelf This pool's sqrtPriceX96 after the swap.
    /// @param tickSelf This pool's tick after the swap.
    /// @param sqrtPriceAnchor The anchor pool's sqrtPriceX96, or zero if no anchor is set or the read failed.
    /// @param tickAnchor The anchor pool's tick, or zero under the same conditions.
    /// @param swapAmount `amountSpecified` of the swap: negative for exact input, positive for exact output.
    /// @param zeroForOne The swap's direction.
    /// @param feeAmount Estimated LP fee paid: the input actually taken times the pool's LP fee over 1e6.
    /// @param liquidity This pool's in-range liquidity after the swap.
    event PoolData(
        uint256 indexed blockNumber,
        uint160 sqrtPriceSelf,
        int24 tickSelf,
        uint160 sqrtPriceAnchor,
        int24 tickAnchor,
        int256 swapAmount,
        bool zeroForOne,
        uint256 feeAmount,
        uint128 liquidity
    );
    event AnchorSet(address indexed anchor, bytes32 indexed poolId);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotPoolManager();
    error NotOwner();
    error ZeroAddress();

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param owner_ The administrator (manifest: "$owner"). Never the deploying factory.
    constructor(IPoolManager poolManager_, address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ───────────────────────────── administration ─────────────────────────────

    /// @notice Point the hook at an anchor pool. `anchor_` must answer `getSlot0(bytes32)`; a v4
    /// `StateView` is the usual choice. Set `anchor_` to zero to stop reading an anchor.
    function setAnchor(address anchor_, bytes32 poolId_) external onlyOwner {
        anchor = anchor_;
        anchorPoolId = poolId_;
        emit AnchorSet(anchor_, poolId_);
    }

    /// @notice Pause or resume emission. Swaps are never blocked by this hook.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Hand administration to `newOwner`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─────────────────────────────── callbacks ────────────────────────────────

    /// @notice The permissions the deployed address must carry: beforeInitialize and afterSwap.
    /// @dev ABI-encodes the fourteen booleans by hand (448 zeroed bytes, two set to one): the
    /// struct literal costs over a hundred bytes of runtime and this hook has a 2 KB budget.
    /// `_permissions()` is the same answer as a struct, for the constructor's self-check.
    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            // Copying from past the end of calldata zero-fills the 14 words.
            calldatacopy(p, calldatasize(), 448)
            mstore(p, 1) // beforeInitialize
            mstore(add(p, 224), 1) // afterSwap
            return(p, 448)
        }
    }

    function _permissions() private pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Accepts any pool opened on this hook. Present so the pool cannot be initialized
    /// before the hook exists; it imposes no fee or spacing rule.
    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Reads this pool and the anchor, emits `PoolData`, returns no delta.
    /// @dev The pool id is `keccak256(abi.encode(key))`. The key is a static tuple that sits in
    /// calldata at offset 36 (selector, then `sender`), so hashing those 160 bytes in place is the
    /// same id without copying the struct to memory; that copy alone costs over fifty bytes of code.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!paused) {
            PoolId id;
            assembly ("memory-safe") {
                let p := mload(0x40)
                calldatacopy(p, 36, 160)
                id := keccak256(p, 160)
            }
            (uint160 sqrtPriceSelf, int24 tickSelf,, uint24 lpFee) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);

            // The swapper's delta: the side it paid is negative. `paid` is an int128, so negating it
            // fits a uint128, and a uint128 times a uint24 cannot overflow a uint256.
            int128 paid = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 feeAmount;
            unchecked {
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 input = paid < 0 ? uint256(uint128(-paid)) : 0;
                feeAmount = input * lpFee / 1_000_000;
            }

            (uint160 sqrtPriceAnchor, int24 tickAnchor) = _readAnchor();

            emit PoolData(
                block.number,
                sqrtPriceSelf,
                tickSelf,
                sqrtPriceAnchor,
                tickAnchor,
                params.amountSpecified,
                params.zeroForOne,
                feeAmount,
                liquidity
            );
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev `staticcall anchor.getSlot0(anchorPoolId)`. Returns zeros while unset, or when the call
    /// fails or answers fewer than two words, so a misconfigured anchor can never block a swap.
    function _readAnchor() private view returns (uint160 sqrtPriceAnchor, int24 tickAnchor) {
        address target = anchor;
        if (target == address(0)) return (0, 0);
        bytes32 poolId = anchorPoolId;
        assembly ("memory-safe") {
            let p := mload(0x40)
            // getSlot0(bytes32) selector, left-aligned
            mstore(p, 0xc815641c00000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 4), poolId)
            let ok := staticcall(gas(), target, p, 36, p, 64)
            if and(ok, gt(returndatasize(), 63)) {
                sqrtPriceAnchor := and(mload(p), 0xffffffffffffffffffffffffffffffffffffffff)
                tickAnchor := signextend(2, mload(add(p, 32)))
            }
        }
    }
}
