// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SiphonHook} from "../src/SiphonHook.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {LimitSwapper} from "./mocks/LimitSwapper.sol";
import {LiquidityRouter} from "./mocks/LiquidityRouter.sol";
import {AnchorView, FixedAnchor} from "./mocks/AnchorView.sol";
import {
    DirtyAnchor,
    StateWritingAnchor,
    ReturnBombAnchor,
    GasBurningAnchor,
    EchoAnchor
} from "./mocks/HostileAnchors.sol";

/// @notice Inputs the first suite did not try: price-limited partial fills, swaps that leave the
/// liquidity range, extreme and dynamic LP fees, the LP fee the pool actually charged, oversized hook
/// data, hostile anchors, repeated and degenerate admin calls, and the int128 edge of the delta.
contract SiphonHookEdgesTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant FEE = 12_500;
    int24 constant SPACING = 60;
    uint128 constant LIQUIDITY = 1e21;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP;
    bytes32 constant POOL_DATA_SIG =
        keccak256("PoolData(uint256,uint160,int24,uint160,int24,int256,bool,uint256,uint128)");
    bytes32 constant SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager manager;
    SiphonToken token;
    SiphonHook hook;
    Swapper swapper;
    LimitSwapper limitSwapper;
    LiquidityRouter lp;
    MockERC20 tokA;
    MockERC20 tokB;

    PoolKey key;
    PoolId id;

    address owner = makeAddr("owner");
    address factory = makeAddr("factory");
    address stranger = makeAddr("stranger");

    struct Data {
        uint256 blockNumber;
        uint160 sqrtPriceSelf;
        int24 tickSelf;
        uint160 sqrtPriceAnchor;
        int24 tickAnchor;
        int256 swapAmount;
        bool zeroForOne;
        uint256 feeAmount;
        uint128 liquidity;
    }

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.prank(factory);
        token = new SiphonToken();
        hook = deployHook(owner);

        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), FEE, SPACING, IHooks(address(hook)));
        id = key.toId();
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        lp = new LiquidityRouter(manager);
        vm.deal(address(lp), 1e24);
        vm.prank(factory);
        token.transfer(address(lp), 1e26);
        lp.modify(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), int256(uint256(LIQUIDITY)));

        swapper = new Swapper(manager);
        vm.deal(address(swapper), 1e24);
        vm.prank(factory);
        token.transfer(address(swapper), 1e26);

        limitSwapper = new LimitSwapper(manager);
        vm.deal(address(limitSwapper), 1e24);
        vm.prank(factory);
        token.transfer(address(limitSwapper), 1e26);

        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (tokA, tokB) = address(a) < address(b) ? (a, b) : (b, a);
        tokA.mint(address(lp), 1e30);
        tokB.mint(address(lp), 1e30);
        tokA.mint(address(limitSwapper), 1e30);
        tokB.mint(address(limitSwapper), 1e30);
        tokA.mint(address(swapper), 1e30);
        tokB.mint(address(swapper), 1e30);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function deployHook(address owner_) internal returns (SiphonHook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(SiphonHook).creationCode, abi.encode(manager, owner_)));
        for (uint256 i = 0; i < 100_000; i++) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            return new SiphonHook{salt: bytes32(i)}(manager, owner_);
        }
        revert("no salt found");
    }

    /// @dev Opens an A/B pool on the hook with `fee`, and liquidity on [lower, upper] when nonzero.
    function openPool(uint24 fee, int24 lower, int24 upper, uint128 liquidity) internal returns (PoolKey memory k) {
        k = PoolKey(Currency.wrap(address(tokA)), Currency.wrap(address(tokB)), fee, SPACING, IHooks(address(hook)));
        manager.initialize(k, SQRT_PRICE_1_1);
        if (liquidity > 0) lp.modify(k, lower, upper, int256(uint256(liquidity)));
    }

    function poolDataLogs() internal view returns (Data[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == POOL_DATA_SIG) n++;
        }
        out = new Data[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != POOL_DATA_SIG) continue;
            Data memory d = out[j++];
            d.blockNumber = uint256(logs[i].topics[1]);
            (
                d.sqrtPriceSelf,
                d.tickSelf,
                d.sqrtPriceAnchor,
                d.tickAnchor,
                d.swapAmount,
                d.zeroForOne,
                d.feeAmount,
                d.liquidity
            ) = abi.decode(logs[i].data, (uint160, int24, uint160, int24, int256, bool, uint256, uint128));
        }
    }

    function onlyPoolData() internal view returns (Data memory) {
        Data[] memory all = poolDataLogs();
        assertEq(all.length, 1, "exactly one PoolData per swap");
        return all[0];
    }

    function assertSelfState(Data memory d, PoolId pool) internal view {
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(pool);
        assertEq(d.sqrtPriceSelf, sqrtPrice, "sqrtPriceSelf");
        assertEq(d.tickSelf, tick, "tickSelf");
        assertEq(d.liquidity, manager.getLiquidity(pool), "liquidity");
    }

    function paidOf(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        return paid < 0 ? uint256(uint128(-paid)) : 0;
    }

    /// @dev The LP fee the pool credited to its in-range liquidity during one swap, from fee growth.
    function feeGrowth(PoolId pool, bool zeroForOne) internal view returns (uint256) {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(pool);
        return zeroForOne ? g0 : g1;
    }

    function setAnchor(address anchor_, bytes32 poolId) internal {
        vm.prank(owner);
        hook.setAnchor(anchor_, poolId);
    }

    // ───────────────────────────── swap context edges ─────────────────────────────

    function test_priceLimitedPartialFillReportsFeeOnWhatWasActuallyPaid() public {
        // Ask to sell 1000 ETH but stop at tick -100: the pool takes far less than asked.
        uint160 limit = TickMath.getSqrtPriceAtTick(-100);
        vm.recordLogs();
        BalanceDelta delta = limitSwapper.swap(key, SwapParams(true, -1000 ether, limit), "");
        Data memory d = onlyPoolData();

        uint256 paid = paidOf(delta, true);
        assertLt(paid, 1000 ether, "partial fill");
        assertGt(paid, 0);
        assertEq(d.swapAmount, -1000 ether, "swapAmount is what was asked, not what was filled");
        assertEq(d.sqrtPriceSelf, limit, "stopped at the limit");
        assertEq(d.feeAmount, paid * FEE / 1_000_000, "fee on the filled input");
        assertSelfState(d, id);
    }

    function test_swapLeavingTheLiquidityRangeReportsZeroLiquidity() public {
        PoolKey memory k = openPool(3000, -600, 600, 1e20);
        uint160 limit = TickMath.getSqrtPriceAtTick(-1200);
        vm.recordLogs();
        BalanceDelta delta = limitSwapper.swap(k, SwapParams(true, -1e30, limit), "");
        Data memory d = onlyPoolData();

        assertEq(d.liquidity, 0, "price left the only position");
        assertEq(d.sqrtPriceSelf, limit);
        assertEq(d.tickSelf, -1200);
        assertSelfState(d, k.toId());
        assertEq(d.feeAmount, paidOf(delta, true) * 3000 / 1_000_000);
    }

    function test_maximumLpFeeReportsTheWholeInputAsFee() public {
        PoolKey memory k = openPool(uint24(LPFeeLibrary.MAX_LP_FEE), -600, 600, 1e20);
        vm.recordLogs();
        BalanceDelta delta = limitSwapper.swap(k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        Data memory d = onlyPoolData();
        assertEq(paidOf(delta, true), 1 ether);
        assertEq(delta.amount1(), 0, "a 100% fee pays nothing out");
        assertEq(d.feeAmount, 1 ether, "the whole input is fee");
        assertEq(d.sqrtPriceSelf, SQRT_PRICE_1_1, "and the price does not move");
    }

    function test_dynamicFeePoolWithNoFeeSetReportsZeroFee() public {
        PoolKey memory k = PoolKey(
            Currency.wrap(address(tokA)),
            Currency.wrap(address(tokB)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SPACING,
            IHooks(address(hook))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
        lp.modify(k, -600, 600, 1e20);
        uint256 before = feeGrowth(k.toId(), true);
        vm.recordLogs();
        limitSwapper.swap(k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        Data memory d = onlyPoolData();
        assertEq(d.feeAmount, 0, "the hook never sets a dynamic fee, so none is charged");
        assertEq(feeGrowth(k.toId(), true), before, "and the pool charged none");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeAmountIsTheLpFeeThePoolCharged(uint256 amount, bool zeroForOne, bool exactIn) public {
        // Exact output is held under the pool's ~1e21 reserve of either side.
        amount = bound(amount, 1, exactIn ? 1e22 : 5e20);
        uint256 before = feeGrowth(id, zeroForOne);
        vm.recordLogs();
        swapper.swapExact(key, zeroForOne, exactIn ? -int256(amount) : int256(amount));
        Data memory d = onlyPoolData();
        // Fee growth is the fee per unit of liquidity, rounded down; one position holds all of it.
        uint256 charged = (feeGrowth(id, zeroForOne) - before) * LIQUIDITY >> 128;
        // v4 rounds the fee up and growth rounds it down; the hook's estimate rounds down. They meet
        // within a couple of wei, never further.
        assertApproxEqAbs(d.feeAmount, charged, 2, "reported fee vs fee the pool charged");
    }

    function test_longHookDataDoesNotShiftThePoolKey() public {
        bytes memory hookData = new bytes(1000);
        for (uint256 i = 0; i < hookData.length; i++) {
            hookData[i] = bytes1(uint8(i));
        }
        vm.recordLogs();
        limitSwapper.swap(key, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1), hookData);
        Data memory d = onlyPoolData();
        assertSelfState(d, id);
        assertEq(d.feeAmount, 1 ether * uint256(FEE) / 1_000_000);
    }

    function test_unitDeltaAtTheInt128Edge() public {
        vm.recordLogs();
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(
            stranger, key, SwapParams(true, type(int256).min, 0), toBalanceDelta(type(int128).min, 0), ""
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        Data memory d = onlyPoolData();
        assertEq(d.feeAmount, uint256(1 << 127) * FEE / 1_000_000, "no overflow at |int128.min|");
        assertEq(d.swapAmount, type(int256).min, "amountSpecified passed through untouched");
    }

    function testFuzz_unitFeeComesOnlyFromTheNegativePaidSide(int128 amount0, int128 amount1, bool zeroForOne) public {
        vm.recordLogs();
        vm.prank(address(manager));
        hook.afterSwap(stranger, key, SwapParams(zeroForOne, -1, 0), toBalanceDelta(amount0, amount1), hex"beef");
        Data memory d = onlyPoolData();
        int128 paid = zeroForOne ? amount0 : amount1;
        uint256 input = paid < 0 ? uint256(-int256(paid)) : 0;
        assertEq(d.feeAmount, input * FEE / 1_000_000);
        assertEq(d.zeroForOne, zeroForOne);
    }

    function test_pausedUnitCallStillReturnsTheSelectorAndNoDelta() public {
        vm.prank(owner);
        hook.setPaused(true);
        vm.recordLogs();
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) =
            hook.afterSwap(stranger, key, SwapParams(true, -1, 0), toBalanceDelta(-1, 1), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertEq(poolDataLogs().length, 0);
    }

    function test_eachPoolDataFollowsTheManagersSwapEventForItsPool() public {
        // PoolData carries no pool id; the manager's Swap event for the same swap is the log just
        // before it, which is how a consumer attributes a record to a pool.
        PoolKey memory other = openPool(3000, -600, 600, 1e20);
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        limitSwapper.swap(other, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[2] memory expected = [PoolId.unwrap(id), PoolId.unwrap(other.toId())];
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != POOL_DATA_SIG) continue;
            assertGt(i, 0);
            Vm.Log memory prev = logs[i - 1];
            assertEq(prev.emitter, address(manager), "previous log is the manager's");
            assertEq(prev.topics[0], SWAP_SIG, "and it is Swap");
            assertEq(prev.topics[1], expected[seen++], "for the pool this record describes");
        }
        assertEq(seen, 2);
    }

    // ───────────────────────────── hostile anchors ─────────────────────────────

    function testFuzz_anchorIsAskedForExactlyTheStoredPoolId(bytes32 poolId) public {
        EchoAnchor echo = new EchoAnchor();
        setAnchor(address(echo), poolId);
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, uint160(uint256(poolId)));
        assertEq(d.tickAnchor, int24(int256(uint256(poolId) % 1000)));
    }

    function test_anchorPoolIdWithoutAnAnchorAddressIsNotRead() public {
        setAnchor(address(0), bytes32(uint256(123)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    function testFuzz_dirtyAnchorWordsAreNarrowedNotTrusted(uint256 priceWord, uint256 tickWord) public {
        DirtyAnchor dirty = new DirtyAnchor(priceWord, tickWord);
        setAnchor(address(dirty), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, uint160(priceWord), "price is the low 160 bits");
        assertEq(d.tickAnchor, int24(int256(tickWord)), "tick is the low 24 bits, sign-extended");
        assertSelfState(d, id);
    }

    function test_anchorThatWritesStateCannotAndReadsAsZero() public {
        StateWritingAnchor writer = new StateWritingAnchor();
        setAnchor(address(writer), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0, "the staticcall forbade the write");
        assertEq(d.tickAnchor, 0);
        assertEq(writer.calls(), 0, "and no state changed");
    }

    function test_anchorWithOversizedAnswerReadsTheFirstTwoWords() public {
        ReturnBombAnchor bomb = new ReturnBombAnchor();
        setAnchor(address(bomb), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0x1000000000000000000000000);
        assertEq(d.tickAnchor, 42);
    }

    function test_gasBurningAnchorReadsAsZeroAndClearingItRestoresTheCost() public {
        // With ample gas the swap survives an anchor that burns everything it is given (see the
        // reported finding for what happens at a realistic gas limit).
        GasBurningAnchor burner = new GasBurningAnchor();
        setAnchor(address(burner), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);

        setAnchor(address(0), bytes32(0));
        uint256 g = gasleft();
        swapper.swap(key, true, 1 ether);
        assertLt(g - gasleft(), 300_000, "a cleared anchor costs an ordinary swap");
    }

    function test_anchorPointingAtTheHookItselfReadsAsZero() public {
        setAnchor(address(hook), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0, "the hook has no getSlot0");
        assertEq(d.tickAnchor, 0);
    }

    function test_anchorPointingAtThePoolManagerReadsAsZero() public {
        // A common misconfiguration: the PoolManager instead of StateView. It has no getSlot0(bytes32).
        setAnchor(address(manager), PoolId.unwrap(id));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    function test_anchorOnAnUninitializedPoolReadsAsZero() public {
        AnchorView view_ = new AnchorView(manager);
        setAnchor(address(view_), keccak256("no such pool"));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    // ───────────────────────────── administration edges ─────────────────────────────

    function test_settersAreIdempotentAndEmitEveryTime() public {
        vm.startPrank(owner);
        for (uint256 i = 0; i < 2; i++) {
            vm.expectEmit(false, false, false, true, address(hook));
            emit SiphonHook.PausedSet(true);
            hook.setPaused(true);
            assertTrue(hook.paused());
        }
        vm.expectEmit(false, false, false, true, address(hook));
        emit SiphonHook.PausedSet(false);
        hook.setPaused(false);
        hook.setPaused(false);
        assertFalse(hook.paused());

        FixedAnchor a = new FixedAnchor(1, 1);
        hook.setAnchor(address(a), bytes32(uint256(5)));
        hook.setAnchor(address(a), bytes32(uint256(5)));
        assertEq(hook.anchor(), address(a));
        assertEq(hook.anchorPoolId(), bytes32(uint256(5)));
        vm.stopPrank();
    }

    function test_transferOwnershipToSelfKeepsControl() public {
        vm.prank(owner);
        hook.transferOwnership(owner);
        assertEq(hook.owner(), owner);
        vm.prank(owner);
        hook.setPaused(true);
        assertTrue(hook.paused());
    }

    function test_previousOwnerLosesEveryPower() public {
        address next = makeAddr("next");
        vm.prank(owner);
        hook.transferOwnership(next);
        vm.startPrank(owner);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setAnchor(owner, bytes32(0));
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setPaused(true);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.transferOwnership(owner);
        vm.stopPrank();
        assertEq(hook.owner(), next);
    }

    function test_poolManagerAndFactoryAreNotAdmins() public {
        address[2] memory callers = [address(manager), factory];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(SiphonHook.NotOwner.selector);
            hook.setAnchor(callers[i], bytes32(0));
            vm.expectRevert(SiphonHook.NotOwner.selector);
            hook.setPaused(true);
            vm.expectRevert(SiphonHook.NotOwner.selector);
            hook.transferOwnership(callers[i]);
            vm.stopPrank();
        }
    }

    function test_failedAdminCallsChangeNothing() public {
        vm.prank(stranger);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setAnchor(stranger, bytes32(uint256(9)));
        vm.prank(owner);
        vm.expectRevert(SiphonHook.ZeroAddress.selector);
        hook.transferOwnership(address(0));
        assertEq(hook.anchor(), address(0));
        assertEq(hook.anchorPoolId(), bytes32(0));
        assertEq(hook.owner(), owner);
        assertFalse(hook.paused());
    }

    function test_beforeInitializeAcceptsThePolicyFeeFromTheManagerOnly() public {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), FEE, 200, IHooks(address(hook)));
        vm.prank(stranger);
        vm.expectRevert(SiphonHook.NotPoolManager.selector);
        hook.beforeInitialize(stranger, k, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(factory, k, TickMath.MIN_SQRT_PRICE), IHooks.beforeInitialize.selector);
    }

    function test_swapsAcrossBlocksCarryTheirOwnBlockNumber() public {
        vm.roll(10);
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        vm.roll(11);
        swapper.swap(key, false, 1 ether);
        Data[] memory all = poolDataLogs();
        assertEq(all.length, 2);
        assertEq(all[0].blockNumber, 10);
        assertEq(all[1].blockNumber, 11);
    }
}
