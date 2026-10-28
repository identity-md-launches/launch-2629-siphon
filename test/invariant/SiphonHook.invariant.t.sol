// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SiphonHook} from "../../src/SiphonHook.sol";
import {SiphonToken} from "../../src/SiphonToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {LiquidityRouter} from "../mocks/LiquidityRouter.sol";
import {AnchorView, RevertingAnchor, FixedAnchor} from "../mocks/AnchorView.sol";

/// @notice Drives the launch pool and the hook's administration in random order: swaps in both
/// directions, exact input and exact output, fee collects, token transfers, and every setter called by
/// the owner and by people who are not. Each swap is checked against the pool as it is afterwards; any
/// disagreement is counted, never reverted, so the invariants see it.
contract SiphonHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 constant POOL_DATA_SIG =
        keccak256("PoolData(uint256,uint160,int24,uint160,int24,int256,bool,uint256,uint128)");
    uint24 constant FEE = 12_500;

    IPoolManager public immutable manager;
    SiphonHook public immutable hook;
    SiphonToken public immutable token;
    Swapper public immutable swapper;
    LiquidityRouter public immutable lp;
    uint128 public immutable liquidity;
    PoolKey key;
    PoolId public id;

    address[] public actors;
    address[4] public anchors; // zero, a StateView-like view, a fixed answer, a reverting one
    bytes32 public anchorPoolIdChoice;
    uint160 public immutable fixedPrice;
    int24 public immutable fixedTick;

    // what the hook should hold, by our own account
    address public ghostOwner;
    bool public ghostPaused;
    address public ghostAnchor;
    bytes32 public ghostAnchorPoolId;

    // what happened
    uint256 public swaps;
    uint256 public unpausedSwaps;
    uint256 public records;
    uint256 public mismatches;
    string public lastMismatch;
    uint256 public secondPoolAttempts;

    constructor(
        IPoolManager manager_,
        SiphonHook hook_,
        SiphonToken token_,
        Swapper swapper_,
        LiquidityRouter lp_,
        PoolKey memory key_,
        uint128 liquidity_,
        address owner_,
        address[] memory actors_,
        bytes32 anchorPoolId_
    ) {
        manager = manager_;
        hook = hook_;
        token = token_;
        swapper = swapper_;
        lp = lp_;
        key = key_;
        id = key_.toId();
        liquidity = liquidity_;
        ghostOwner = owner_;
        actors = actors_;
        anchorPoolIdChoice = anchorPoolId_;
        fixedPrice = TickMath.getSqrtPriceAtTick(-4321);
        fixedTick = -4321;
        anchors[1] = address(new AnchorView(manager_));
        anchors[2] = address(new FixedAnchor(fixedPrice, fixedTick));
        anchors[3] = address(new RevertingAnchor());
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _mismatch(string memory why) internal {
        mismatches++;
        lastMismatch = why;
    }

    function _actor(uint256 seed) internal view returns (address) {
        // One draw in four is the current owner, so the owner's paths are exercised too.
        if (seed % 4 == 0) return hook.owner();
        return actors[seed % actors.length];
    }

    // ───────────────────────────── swaps ─────────────────────────────

    function swap(uint256 amount, bool zeroForOne, bool exactIn) external {
        amount = bound(amount, 1, exactIn ? 1e20 : 1e19);
        int256 specified = exactIn ? -int256(amount) : int256(amount);
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(id);
        uint256 hookEth = address(hook).balance;

        vm.recordLogs();
        BalanceDelta delta = swapper.swapExact(key, zeroForOne, specified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        swaps++;

        uint256 n;
        uint256 at;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook)) {
                if (logs[i].topics[0] == POOL_DATA_SIG) {
                    n++;
                    at = i;
                } else {
                    _mismatch("hook emitted something other than PoolData during a swap");
                }
            }
        }
        if (address(hook).balance != hookEth) _mismatch("hook balance moved in a swap");

        if (ghostPaused) {
            if (n != 0) _mismatch("paused hook emitted");
            return;
        }
        unpausedSwaps++;
        if (n != 1) {
            _mismatch("unpaused swap did not emit exactly once");
            return;
        }
        records++;
        _check(logs[at], delta, zeroForOne, specified, zeroForOne ? g0 : g1);
    }

    function _check(Vm.Log memory log, BalanceDelta delta, bool zeroForOne, int256 specified, uint256 growthBefore)
        internal
    {
        if (uint256(log.topics[1]) != block.number) _mismatch("block number");
        (
            uint160 sqrtSelf,
            int24 tickSelf,
            uint160 sqrtAnchor,
            int24 tickAnchor,
            int256 swapAmount,
            bool dir,
            uint256 feeAmount,
            uint128 liq
        ) = abi.decode(log.data, (uint160, int24, uint160, int24, int256, bool, uint256, uint128));

        (uint160 sqrtNow, int24 tickNow,,) = manager.getSlot0(id);
        if (sqrtSelf != sqrtNow || tickSelf != tickNow) _mismatch("self price/tick");
        if (liq != manager.getLiquidity(id)) _mismatch("liquidity");
        if (swapAmount != specified) _mismatch("swapAmount");
        if (dir != zeroForOne) _mismatch("direction");

        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        uint256 input = paid < 0 ? uint256(uint128(-paid)) : 0;
        if (feeAmount != input * FEE / 1_000_000) _mismatch("feeAmount vs paid input");
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(id);
        uint256 charged = ((zeroForOne ? g0 : g1) - growthBefore) * liquidity >> 128;
        if (feeAmount > charged + 2 || charged > feeAmount + 2) _mismatch("feeAmount vs fee the pool charged");

        (uint160 wantPrice, int24 wantTick) = _expectedAnchor();
        if (sqrtAnchor != wantPrice || tickAnchor != wantTick) _mismatch("anchor fields");
    }

    function _expectedAnchor() internal view returns (uint160, int24) {
        if (ghostAnchor == address(0) || ghostAnchor == anchors[3]) return (0, 0);
        if (ghostAnchor == anchors[2]) return (fixedPrice, fixedTick);
        // The view reads the manager: the price of the pool it was pointed at, now.
        (uint160 p, int24 t,,) = manager.getSlot0(PoolId.wrap(ghostAnchorPoolId));
        return (p, t);
    }

    function collect() external {
        lp.modify(key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0);
    }

    function moveTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        // Holders only: the manager's and factory's balances are left to the pool.
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function roll(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 1000));
    }

    // ───────────────────────────── administration ─────────────────────────────

    function setAnchor(uint256 callerSeed, uint256 anchorSeed, bool selfPool) external {
        address caller = _actor(callerSeed);
        address target = anchors[anchorSeed % anchors.length];
        bytes32 poolId = selfPool ? PoolId.unwrap(id) : anchorPoolIdChoice;
        vm.prank(caller);
        try hook.setAnchor(target, poolId) {
            if (caller != ghostOwner) _mismatch("non-owner set the anchor");
            ghostAnchor = target;
            ghostAnchorPoolId = poolId;
        } catch (bytes memory err) {
            if (caller == ghostOwner || bytes4(err) != SiphonHook.NotOwner.selector) _mismatch("setAnchor refusal");
        }
    }

    function setPaused(uint256 callerSeed, bool paused_) external {
        address caller = _actor(callerSeed);
        vm.prank(caller);
        try hook.setPaused(paused_) {
            if (caller != ghostOwner) _mismatch("non-owner paused");
            ghostPaused = paused_;
        } catch (bytes memory err) {
            if (caller == ghostOwner || bytes4(err) != SiphonHook.NotOwner.selector) _mismatch("setPaused refusal");
        }
    }

    function transferOwnership(uint256 callerSeed, uint256 toSeed, bool toZero) external {
        address caller = _actor(callerSeed);
        address to = toZero ? address(0) : actors[toSeed % actors.length];
        vm.prank(caller);
        try hook.transferOwnership(to) {
            if (caller != ghostOwner) _mismatch("non-owner transferred ownership");
            if (to == address(0)) _mismatch("ownership given to zero");
            ghostOwner = to;
        } catch (bytes memory err) {
            bytes4 want = caller != ghostOwner ? SiphonHook.NotOwner.selector : SiphonHook.ZeroAddress.selector;
            if (bytes4(err) != want) _mismatch("transferOwnership refusal");
        }
    }

    /// @dev Anyone, the factory included, opening another pool on the hook must be refused: the hook
    /// serves its first pool only, so the manager never creates the pool.
    function openAnotherPool(uint256 callerSeed, uint24 fee, int24 spacing, uint160 price) external {
        address caller = _actor(callerSeed);
        fee = uint24(bound(fee, 0, 1_000_000));
        spacing = int24(bound(spacing, 1, TickMath.MAX_TICK_SPACING));
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        PoolKey memory k = PoolKey(key.currency0, key.currency1, fee, spacing, key.hooks);
        if (PoolId.unwrap(k.toId()) == PoolId.unwrap(id)) return;
        secondPoolAttempts++;
        vm.prank(caller);
        try manager.initialize(k, price) {
            _mismatch("a second pool opened on the hook");
        } catch {}
        (uint160 p,,,) = manager.getSlot0(k.toId());
        if (p != 0) _mismatch("a second pool exists");
    }

    /// @dev Anyone but the manager calling a callback directly must be refused and change nothing.
    function pokeCallback(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        if (caller == address(manager)) return;
        vm.prank(caller);
        try hook.beforeInitialize(caller, key, TickMath.MIN_SQRT_PRICE) {
            _mismatch("beforeInitialize answered a stranger");
        } catch (bytes memory err) {
            if (bytes4(err) != SiphonHook.NotPoolManager.selector) _mismatch("beforeInitialize refusal");
        }
    }
}

contract SiphonInvariantTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint128 constant LIQUIDITY = 1e21;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    IPoolManager manager;
    SiphonToken token;
    SiphonHook hook;
    Swapper swapper;
    LiquidityRouter lp;
    SiphonHandler handler;
    PoolKey key;
    PoolId anchorId;

    address owner = makeAddr("owner");
    address factory = makeAddr("factory");
    address[] actors;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.prank(factory);
        token = new SiphonToken();

        bytes32 initHash = keccak256(abi.encodePacked(type(SiphonHook).creationCode, abi.encode(manager, owner)));
        for (uint256 i = 0; i < 100_000; i++) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            hook = new SiphonHook{salt: bytes32(i)}(manager, owner);
            break;
        }
        require(address(hook) != address(0), "no salt");

        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        lp = new LiquidityRouter(manager);
        vm.deal(address(lp), 1e24);
        vm.prank(factory);
        token.transfer(address(lp), 1e26);
        lp.modify(key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(uint256(LIQUIDITY)));

        swapper = new Swapper(manager);
        vm.deal(address(swapper), 1e24);
        vm.prank(factory);
        token.transfer(address(swapper), 1e26);

        // A hookless pool for the anchor view to read.
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory anchorKey =
            PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(address(0)));
        manager.initialize(anchorKey, TickMath.getSqrtPriceAtTick(6000));
        anchorId = anchorKey.toId();

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(factory);
        actors.push(address(manager));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(factory);
            token.transfer(actors[i], 1e24);
        }

        handler = new SiphonHandler(
            manager, hook, token, swapper, lp, key, LIQUIDITY, owner, actors, PoolId.unwrap(anchorId)
        );
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_everySwapRecordMatchesThePool() public view {
        assertEq(handler.mismatches(), 0, handler.lastMismatch());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_oneRecordPerUnpausedSwapAndNoneOtherwise() public view {
        assertEq(handler.records(), handler.unpausedSwaps());
        assertLe(handler.unpausedSwaps(), handler.swaps());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_hookHoldsNothing() public view {
        assertEq(address(hook).balance, 0, "ETH");
        assertEq(token.balanceOf(address(hook)), 0, "SIPH");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(0)).toId()), 0, "ETH claims");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()), 0, "SIPH claims");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_adminStateIsExactlyWhatTheOwnerSet() public view {
        assertEq(hook.owner(), handler.ghostOwner(), "owner");
        assertTrue(hook.owner() != address(0), "owner never zero");
        assertEq(hook.paused(), handler.ghostPaused(), "paused");
        assertEq(hook.anchor(), handler.ghostAnchor(), "anchor");
        assertEq(hook.anchorPoolId(), handler.ghostAnchorPoolId(), "anchor pool id");
        assertEq(address(hook.poolManager()), address(manager), "manager is immutable");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_theHookServesTheLaunchPoolForever() public view {
        assertEq(hook.poolId(), PoolId.unwrap(key.toId()), "recorded pool never changes");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_tokenSupplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum = token.balanceOf(factory) + token.balanceOf(address(lp)) + token.balanceOf(address(swapper))
            + token.balanceOf(address(manager)) + token.balanceOf(address(hook));
        for (uint256 i = 0; i < 3; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "every SIPH is held by a known party");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_thePoolStaysLiveWithItsLiquidity() public view {
        // An observe-only hook never moves liquidity or funds: whatever the sequence, the pool is open,
        // funded, and holds exactly the LP's position.
        PoolId id = key.toId();
        (uint160 sqrtPrice,,,) = manager.getSlot0(id);
        assertGt(sqrtPrice, 0, "the pool stays initialized");
        assertGt(address(manager).balance, 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(manager.getLiquidity(id), LIQUIDITY, "liquidity only changes through the LP");
    }
}
