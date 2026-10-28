# SIPHON — observe-only Uniswap v4 hook and launch token

Two contracts, built for an IMD hook launch on Robinhood Chain (chain id 4663):

| Contract | File | What it is |
| --- | --- | --- |
| `SiphonToken` | `src/SiphonToken.sol` | The launch token. Name `SIPHON`, symbol `SIPH`, 18 decimals, 1,000,000,000 tokens (10^27 minor units) minted once to the deployer. No owner, mint, pause, blocklist, fee or upgrade. |
| `SiphonHook` | `src/SiphonHook.sol` | The pool's hook. `afterSwap` reads the pool and an optional anchor pool and emits one `PoolData` event per swap. No fee, no return delta, no transient storage, no swap execution, no custody. Runtime is 2030 bytes, under the 2 KB budget. |

`src/HookFlags.sol` is an internal library mapping permission bits to addresses; the floor tests and the
deploy script use it.

## What the hook does

The hook serves exactly one pool: the first one initialized on it, whose id it records in `poolId`.
The launch factory deploys the hook and opens the launch pool in the same transaction, so that pool is
always the launch pool. Every later `initialize` naming the hook is refused (`PoolAlreadyInitialized`),
so no other pool can make the hook emit `PoolData`.

On every swap in that pool, after the swap has executed:

1. If `paused` is set, return immediately. Nothing is read or emitted. The swap itself is never
   blocked by this hook.
2. Read this pool's `sqrtPriceX96`, `tick` and LP fee from slot0, and its in-range `liquidity`, through
   the PoolManager's `extsload` (v4-core's `StateLibrary`).
3. If `anchor != address(0)`: `staticcall anchor.getSlot0(anchorPoolId)`, selector `0xc815641c`, and
   take the first two return words as the anchor's `sqrtPriceX96` and `tick`. If the call fails,
   returns fewer than two words, or the anchor has no code, both values are reported as zero and the
   swap proceeds. The call is given at most 50,000 gas (`ANCHOR_GAS`; a `StateView` read costs well
   under 10k), so an anchor that reverts, loops or burns its gas costs a swap at most that much and
   cannot halt trading at ordinary gas limits.
4. Emit:

```solidity
event PoolData(
    uint256 indexed blockNumber, // block.number
    uint160 sqrtPriceSelf,       // this pool, after the swap
    int24   tickSelf,
    uint160 sqrtPriceAnchor,     // 0 when no anchor is set or the read failed
    int24   tickAnchor,          // 0 under the same conditions
    int256  swapAmount,          // params.amountSpecified: negative = exact input, positive = exact output
    bool    zeroForOne,          // params.zeroForOne
    uint256 feeAmount,           // nominal LP fee: input actually paid (from the BalanceDelta) * lpFee / 1e6
    uint128 liquidity            // this pool's in-range liquidity after the swap
);
```

5. Return `(afterSwap.selector, 0)`: no hook delta, ever.

### Interpretation choices (the brief leaves these open)

- **`swapAmount`** is the swap's `amountSpecified` exactly as the router passed it, so sign tells exact
  input from exact output. The amount actually paid is recoverable from `feeAmount` and the pool's fee.
- **`feeAmount`** is an estimate of the LP fee: the input the swapper actually paid (the negative side
  of its `BalanceDelta`) times the pool's LP fee over 1e6. It is not read from the pool's fee growth
  accumulators. While the PoolManager's protocol fee is zero it matches v4's per-step fee to within
  rounding for single-step swaps. If the PoolManager's owner sets a protocol fee (at most 1000 pips,
  0.1%, per direction), v4 charges `protocolFee + lpFee - protocolFee * lpFee / 1e6` and credits LPs
  the LP share net of the protocol's cut, so `feeAmount` then slightly overstates the LP fee credited
  and understates the total fee paid, by at most about 0.1% of the input.
- **`blockNumber`** is `block.number`. Robinhood Chain runs Arbitrum Nitro, where `block.number`
  is the L1 block number the sequencer observed, not the L2 block. Consumers that need wall time
  should read the block's timestamp from the receipt.
- **Pause** silences emission and skips the anchor read. It does not revert swaps: an observe-only
  hook that could freeze its pool would be a worse failure than a gap in the data. This is a
  documented divergence from "pause means revert" if that was intended.
- **Anchor** is two values, not one: the brief says "anchor pool address", but selector `0xc815641c`
  is `getSlot0(bytes32)`, which takes a pool id. So `setAnchor(address anchor, bytes32 poolId)` stores
  both. The anchor contract is anything that answers `getSlot0(bytes32)` with slot0's layout, in
  practice Uniswap's `StateView` for the chain's PoolManager, with the v4 pool id of the pool to track.

### Callbacks and permissions

The brief asks for `afterSwap` only. IMD launches additionally require an initialization callback, so
nobody can initialize the predicted pool while the hook has no code. `beforeInitialize` is enabled and
implemented: it checks the caller is the PoolManager, records the pool's id in `poolId` if none is
recorded yet, reverts with `PoolAlreadyInitialized` otherwise, and returns its selector. It imposes no
fee, spacing or currency rule, so the factory opens the launch pool (ETH / SIPH, fee 12500, spacing 60)
without restriction. Nobody, the factory included, can open a second pool on the hook: before this
rule any account could open a liquidity-less pool on the hook and swap it for free to make the hook
emit `PoolData` carrying a price of its choosing, indistinguishable from the launch pool's records.
Because the hook and its pool are created in one transaction, nobody can open a pool on the hook
first; and the hook address has no code before that transaction, so `initialize` on it reverts.

No liquidity callbacks exist, so the factory's fee collect (a zero liquidity change, which v4 routes
through the remove-liquidity path) is untouched by the hook. `test_factoryCollectsFeesWithAZeroLiquidityChange`
and the protected owners floor cover it.

Wizard-style configuration record for this hook:

```json
{
  "hook": "BaseHook",
  "name": "SiphonHook",
  "pausable": true,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": false,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

The hook does not inherit v4-periphery's `BaseHook` or OpenZeppelin's `Ownable`/`Pausable`: with their
ten `HookNotImplemented` stubs and string-reverting modifiers the runtime exceeded 2 KB. The same
behaviour is written by hand with custom errors. Permission flags: `0x2040` (`BEFORE_INITIALIZE | AFTER_SWAP`,
decimal 8256). The constructor runs `Hooks.validateHookPermissions`, so a deployment to an address
without exactly those bits reverts.

### Size measures, and why they are safe

Three deliberate choices keep the runtime under 2 KB; each is commented in the source.

- `getHookPermissions()` ABI-encodes its fourteen booleans in assembly (448 zero bytes with word 0
  and word 7 set to one) instead of building the struct. The constructor's self-check uses an ordinary
  struct built by `_permissions()`, which only exists in creation code.
- `beforeInitialize` hashes the `PoolKey` where it sits in calldata (offset 36, 160 bytes) instead of
  copying it to memory; `keccak256(abi.encode(key))` is by definition the pool id. `afterSwap` reads
  the recorded `poolId`, which is the only pool that can call it.
- The anchor read is a hand-written `staticcall` with a fixed 64-byte return area. It uses `and` and
  `signextend`, never Yul shifts.

The hook holds no funds and returns no deltas, so none of these affect accounting.

## Constructor arguments and the launch manifest

```
SiphonToken()                                     // no arguments
SiphonHook(IPoolManager poolManager_, address owner_)
```

| Argument | Manifest value | Notes |
| --- | --- | --- |
| `poolManager_` | `"$poolManager"` | The chain's Uniswap v4 PoolManager. Never hardcoded. |
| `owner_` | `"$owner"` | Resolves to `0x735121a546092f31050a867fd7e3a750c7b0eff9`. Zero is refused. The factory (`msg.sender`) and IMD's wallet (`tx.origin`) are never the owner. |

The constructor calls no other contract. Launch pool terms (decided by the launch, not here): native
ETH pair, LP fee 12500 (1.25%), tick spacing 60; the deployer sets the opening price. The hook takes
no fee of its own, so "no fee" is honoured exactly as the launch policy reads it: no hook fee, no LP
fee override, no deltas; the pool's 1.25% LP fee is the policy's and stays.

Do not write `launch.json`; the manifest step does, after acceptance.

## After launch: owner settings

| Setting | Setter | Set it to | Where the owner gets it |
| --- | --- | --- | --- |
| Anchor | `setAnchor(address anchor, bytes32 poolId)` | The chain's Uniswap v4 `StateView` address and the v4 pool id (`keccak256(abi.encode(PoolKey))`) of the pool to track. Pass `(address(0), 0)` to stop reading an anchor. | Uniswap's deployment list for Robinhood Chain (StateView), and the tracked pool's key from its initialize event or any v4 explorer. |
| Pause | `setPaused(bool)` | `true` to silence `PoolData`, `false` to resume. | Operational decision. |
| Owner | `transferOwnership(address)` | A multisig is recommended once the data pipeline is stable. Single-step: double-check the address. | — |

Until `setAnchor` is called the hook emits `PoolData` with zero anchor fields; nothing else is gated on it
and nothing reverts for lack of it. Every setter emits an event (`AnchorSet`, `PausedSet`,
`OwnershipTransferred`).

The anchor pool id is not a stand-in or a guess for anything: it is empty until the owner has a pool to
track, and the hook behaves correctly either way (both states are tested).

## Operational responsibilities and trust assumptions

- **Owner powers**: set or clear the anchor, pause and resume emission, transfer ownership. The owner
  cannot block swaps, take fees, move funds, change the pool's fee or upgrade the code. The pause is a
  data switch only.
- **Anchor trust**: the owner chooses the anchor contract. A dishonest or broken anchor can only
  make the anchor fields wrong or zero; it cannot revert swaps or touch funds. Its `staticcall` gets
  at most 50,000 gas, so a pathological anchor adds at most that to each swap's cost until the owner
  clears it. Prefer Uniswap's own `StateView`, and never an anchor whose code a third party can change.
- **Data consumers**: `PoolData` is emitted inside the swap transaction. Indexers should key on
  `(transactionHash, logIndex)`; `blockNumber` is the Arbitrum-style L1 block number, see above. Every
  `PoolData` from the hook's address describes the pool whose id is `poolId()`.
- **Not a price oracle**: `sqrtPriceSelf` and `sqrtPriceAnchor` are spot values read inside the swap's
  transaction. Anyone with capital can, in one transaction, move the anchor pool, make a dust swap in
  the launch pool so a record carries the displaced prices, and move the anchor back. A single record
  is a raw per-swap observation; consumers that price SIPH from this feed must aggregate across blocks
  (time-weighted, outlier-filtered) themselves.
- **Ownership transfer is single-step**: `transferOwnership` takes effect at once, with only a zero
  check. A transfer to an address nobody controls fixes the anchor and pause settings forever (swaps
  and fee collection are unaffected). Verify the new owner address before sending, prefer a multisig,
  and consider a test call from it first. A two-step accept was left out for the 2 KB budget.
- **Nothing to fund or withdraw**: the hook never holds ETH, tokens or ERC-6909 claims, and has no
  `receive`/`fallback`.
- **Gas**: `afterSwap` costs roughly 10k gas (two `extsload`s, one `LOG2` with eight data words) plus the
  anchor `staticcall` when set.
- **No upgrade path**: no proxy, no `delegatecall`, no `selfdestruct` (both the token and the hook
  are scanned for these in tests).
- **Security review**: tests passing are not an audit. Independent adversarial review before release
  is the launch process's responsibility. Slither and Mythril were not available on this machine;
  the code was written around the verifier's six rejected detectors (no `selfdestruct`, no
  `transferFrom` from anyone but `msg.sender`, no initializers, no uninitialized storage pointers,
  no Yul shifts, no `abi.encodePacked` of consecutive dynamic values).

## What the brief asked that the token does not do

Nothing extra was asked of the token; it is the standard launch token. Owner and pause powers live in
the hook, as the launch rules require. The token has no admin at all.

## Build and test

```
forge build
forge test
forge fmt --check
```

- `foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `via_ir = true`,
  `optimizer_runs = 200`, `bytecode_hash = "none"`, `cbor_metadata = false`, `ffi = false`, no
  `fs_permissions`. via-IR is required: the nine-field emit exceeds the legacy pipeline's stack and
  via-IR also produces the smaller runtime.
- Dependencies are vendored as plain files under `lib/` (no submodules): forge-std, Uniswap v4-core,
  OpenZeppelin Contracts v5.4.0 and solmate (v4-core's `Owned`). Remappings are in `remappings.txt`.
  Each library's own nested `.gitmodules` text file is left in place; git reads only the root
  `.gitmodules`, and the directories those files describe were removed.
- Tests read no environment variables and run in any order. Fuzz tests pass with
  `FOUNDRY_FUZZ_SEED=0x09d38982aa32aa431f5324d537dc0088eb1cc2e4ab9f1fcd46337c503b8619a1`.

### Test coverage

`test/SiphonHook.t.sol` (39 tests): constructor state and zero-owner refusal, address/permission
agreement, runtime size under 2 KB, opcode scan, callbacks refusing non-manager callers, first-pool-only
initialization (no second pool on the hook, from a stranger or the factory, and no forged `PoolData`
through a liquidity-less pool), owner-only
setters with events, ownership transfer, exact-input buy and sell, exact-output swaps, one event per
swap, block number topic, anchor read through a StateView-like contract against a second live pool,
anchor pool id routing, negative tick sign extension, reverting/short/code-less anchors reading as
zero without blocking the swap, clearing the anchor, pause silencing emission while swaps still execute
and skipping the anchor call, a gas-burning anchor bounded by its stipend at a 300k swap gas limit,
unit tests of `afterSwap` as the manager (fee from the paid side, zero fee when nothing was paid, the
recorded pool read whatever key is passed), no fee/no custody/no claims, factory fee
collect with a zero liquidity change, liquidity removal, and four fuzz tests (exact input, exact
output, anchor pass-through, access control).

`test/SiphonToken.t.sol` (8): metadata, supply to deployer, transfer, transferFrom with and without
allowance, over-balance revert, absence of mint/burn/owner/pause entry points, supply conservation fuzz.

`test/HookFlags.t.sol` (3) and `test/DeploySiphon.t.sol` (2): flag constants against v4-core, address
matching, and the deploy script's salt mining and deployment called directly.

`test/mocks/` holds `MockERC20`, `Swapper` (an exact-input/exact-output router paying from its own
balance, native ETH aware), `LiquidityRouter`, and `AnchorView` with four misbehaving anchors, and
`DustSwapper` (a swap that settles nothing, for the forged-record test).
`test/floor/OwnerChecks.sol` asserts an owned contract's owner is neither the factory nor the launch wallet.

## Deploy script

`script/DeploySiphon.s.sol` is a rehearsal only: IMD's factory performs the launch from the attested
bytecode. `mineSalt(deployer, poolManager, owner)` finds a CREATE2 salt landing on the permission bits,
`deployHook(poolManager, owner, salt)` and `deployToken()` deploy; `run()` reads `POOL_MANAGER` and
`OWNER` from the environment and uses the deterministic CREATE2 deployer. Tests call the functions
directly, never `run()`.
