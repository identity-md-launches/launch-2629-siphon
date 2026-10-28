// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SiphonHook} from "../src/SiphonHook.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {LiquidityRouter} from "./mocks/LiquidityRouter.sol";
import {AnchorView, RevertingAnchor, FixedAnchor, ShortAnchor, GasBurningAnchor} from "./mocks/AnchorView.sol";
import {DustSwapper} from "./mocks/DustSwapper.sol";

contract SiphonHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant FEE = 12_500;
    int24 constant SPACING = 60;
    int24 constant ANCHOR_TICK = 6000;
    uint128 constant LIQUIDITY = 1e21;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP;
    bytes32 constant POOL_DATA_SIG =
        keccak256("PoolData(uint256,uint160,int24,uint160,int24,int256,bool,uint256,uint128)");

    IPoolManager manager;
    SiphonToken token;
    SiphonHook hook;
    Swapper swapper;
    LiquidityRouter lp;
    AnchorView anchorView;

    PoolKey key;
    PoolId id;
    PoolKey anchorKey;
    PoolId anchorId;

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

        // The launch pool: native ETH against SIPH at the policy's fee and spacing, opened by the factory.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(hook))
        });
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

        // An unrelated pool with no hook, at a different price, to serve as the anchor.
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        anchorKey = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        anchorId = anchorKey.toId();
        manager.initialize(anchorKey, TickMath.getSqrtPriceAtTick(ANCHOR_TICK));
        anchorView = new AnchorView(manager);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function deployHook(address owner_) internal returns (SiphonHook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(SiphonHook).creationCode, abi.encode(manager, owner_)));
        for (uint256 i = 0; i < 100_000; i++) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            SiphonHook deployed = new SiphonHook{salt: bytes32(i)}(manager, owner_);
            assertEq(address(deployed), predicted, "create2 prediction");
            return deployed;
        }
        revert("no salt found");
    }

    /// @dev The PoolData records the hook emitted since the last `vm.recordLogs()`.
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
            assertEq(logs[i].topics.length, 2, "block number is the one indexed topic");
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

    function assertSelfState(Data memory d) internal view {
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(id);
        assertEq(d.blockNumber, block.number, "block");
        assertEq(d.sqrtPriceSelf, sqrtPrice, "sqrtPriceSelf");
        assertEq(d.tickSelf, tick, "tickSelf");
        assertEq(d.liquidity, manager.getLiquidity(id), "liquidity");
    }

    // ───────────────────────────── deployment ─────────────────────────────

    function test_constructorState() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.owner(), owner);
        assertEq(hook.anchor(), address(0));
        assertEq(hook.anchorPoolId(), bytes32(0));
        assertFalse(hook.paused());
        assertEq(hook.poolId(), PoolId.unwrap(id), "the factory's pool is recorded as the hook's pool");
        assertTrue(hook.owner() != factory && hook.owner() != address(this));
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(SiphonHook.ZeroAddress.selector);
        new SiphonHook(manager, address(0));
    }

    function test_constructorRejectsAnAddressWithoutItsFlags() public {
        // A plain `new` lands on an address whose low bits almost surely disagree with the permissions.
        vm.expectRevert();
        new SiphonHook{salt: bytes32(uint256(0xBAD))}(manager, owner);
    }

    function test_permissionsMatchTheAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.afterSwap);
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeSwap || p.beforeDonate || p.afterDonate || p.beforeSwapReturnDelta
                || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
    }

    function test_runtimeIsUnderTwoKilobytes() public view {
        assertLt(address(hook).code.length, 2048, "runtime over 2 KB");
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(hook).code;
        bool reachable = true;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    // ───────────────────────────── access control ─────────────────────────────

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(SiphonHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(SiphonHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, 0), toBalanceDelta(-1, 1), "");

        vm.prank(owner);
        vm.expectRevert(SiphonHook.NotPoolManager.selector);
        hook.afterSwap(owner, key, SwapParams(true, -1 ether, 0), toBalanceDelta(-1, 1), "");
    }

    function test_beforeInitializeReturnsItsSelectorAndRecordsTheFirstPoolOnly() public {
        SiphonHook fresh = deployHook(makeAddr("other owner"));
        assertEq(fresh.poolId(), bytes32(0), "no pool before initialize");

        vm.prank(address(manager));
        assertEq(fresh.beforeInitialize(factory, key, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
        assertEq(fresh.poolId(), keccak256(abi.encode(key)), "the id is keccak256(abi.encode(key))");

        // Any second pool, even the same key again, is refused.
        vm.prank(address(manager));
        vm.expectRevert(SiphonHook.PoolAlreadyInitialized.selector);
        fresh.beforeInitialize(factory, anchorKey, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        vm.expectRevert(SiphonHook.PoolAlreadyInitialized.selector);
        fresh.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        assertEq(fresh.poolId(), keccak256(abi.encode(key)), "unchanged");
    }

    function test_nobodyCanOpenAnotherPoolOnTheHook() public {
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.prank(stranger);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);

        // Not the factory either: the hook serves exactly one pool.
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);

        (uint160 sqrtPrice,,,) = manager.getSlot0(other.toId());
        assertEq(sqrtPrice, 0, "the second pool was never opened");
        assertEq(hook.poolId(), PoolId.unwrap(id));
    }

    function test_strangerCannotForgePoolDataThroughAnEmptyPool() public {
        // A liquidity-less pool would let a swap walk the price anywhere for free; it cannot be opened.
        PoolKey memory forged = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.startPrank(stranger);
        DustSwapper dust = new DustSwapper(manager);
        vm.expectRevert();
        manager.initialize(forged, TickMath.getSqrtPriceAtTick(-887_000));
        vm.recordLogs();
        vm.expectRevert();
        dust.swap(forged, false, -1, TickMath.getSqrtPriceAtTick(-886_900));
        vm.stopPrank();
        assertEq(poolDataLogs().length, 0, "no PoolData for a pool the hook does not serve");
    }

    function test_setAnchorOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));

        vm.prank(factory);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));

        vm.expectEmit(true, true, false, true, address(hook));
        emit SiphonHook.AnchorSet(address(anchorView), PoolId.unwrap(anchorId));
        vm.prank(owner);
        hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));
        assertEq(hook.anchor(), address(anchorView));
        assertEq(hook.anchorPoolId(), PoolId.unwrap(anchorId));
    }

    function test_setPausedOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setPaused(true);

        vm.expectEmit(false, false, false, true, address(hook));
        emit SiphonHook.PausedSet(true);
        vm.prank(owner);
        hook.setPaused(true);
        assertTrue(hook.paused());

        vm.prank(owner);
        hook.setPaused(false);
        assertFalse(hook.paused());
    }

    function test_transferOwnership() public {
        address next = makeAddr("next");

        vm.prank(stranger);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.transferOwnership(next);

        vm.prank(owner);
        vm.expectRevert(SiphonHook.ZeroAddress.selector);
        hook.transferOwnership(address(0));

        vm.expectEmit(true, true, false, true, address(hook));
        emit SiphonHook.OwnershipTransferred(owner, next);
        vm.prank(owner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), next);

        vm.prank(owner);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setPaused(true);

        vm.prank(next);
        hook.setPaused(true);
        assertTrue(hook.paused());
    }

    // ───────────────────────────── afterSwap: emission ─────────────────────────────

    function test_exactInputBuyEmitsPoolDataWithoutAnchor() public {
        uint256 amountIn = 1 ether;
        vm.recordLogs();
        BalanceDelta delta = swapper.swap(key, true, amountIn);
        Data memory d = onlyPoolData();

        assertSelfState(d);
        assertEq(d.sqrtPriceAnchor, 0, "no anchor: zero price");
        assertEq(d.tickAnchor, 0, "no anchor: zero tick");
        assertEq(d.swapAmount, -int256(amountIn), "amountSpecified");
        assertTrue(d.zeroForOne);
        assertEq(delta.amount0(), -int128(int256(amountIn)), "paid exactly the input");
        assertEq(d.feeAmount, amountIn * FEE / 1_000_000, "fee on the input");
        assertEq(d.liquidity, LIQUIDITY);
        assertLt(d.sqrtPriceSelf, SQRT_PRICE_1_1, "a buy of currency1 lowers the price");
    }

    function test_exactInputSellEmitsPoolData() public {
        uint256 amountIn = 3 ether;
        vm.recordLogs();
        swapper.swap(key, false, amountIn);
        Data memory d = onlyPoolData();

        assertSelfState(d);
        assertEq(d.swapAmount, -int256(amountIn));
        assertFalse(d.zeroForOne);
        assertEq(d.feeAmount, amountIn * FEE / 1_000_000, "fee on the token input");
        assertGt(d.sqrtPriceSelf, SQRT_PRICE_1_1, "a sale of currency1 raises the price");
    }

    function test_exactOutputSwapReportsPositiveAmountAndFeeOnInput() public {
        int256 amountOut = 0.5 ether;
        vm.recordLogs();
        BalanceDelta delta = swapper.swapExact(key, false, amountOut);
        Data memory d = onlyPoolData();

        assertSelfState(d);
        assertEq(d.swapAmount, amountOut, "exact output is positive");
        assertFalse(d.zeroForOne);
        assertEq(delta.amount0(), int128(amountOut), "received the exact output");
        uint256 input = uint256(uint128(-delta.amount1()));
        assertGt(input, uint256(amountOut), "paid more than received at 1:1 plus fee");
        assertEq(d.feeAmount, input * FEE / 1_000_000, "fee on what was actually paid");
    }

    function test_everySwapEmitsOnce() public {
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        swapper.swap(key, false, 2 ether);
        swapper.swapExact(key, true, 0.25 ether);
        Data[] memory all = poolDataLogs();
        assertEq(all.length, 3);
        assertTrue(all[0].zeroForOne && !all[1].zeroForOne && all[2].zeroForOne);
        assertEq(all[2].swapAmount, 0.25 ether);
    }

    function test_blockNumberIsTheIndexedTopic() public {
        vm.roll(123_456);
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        assertEq(onlyPoolData().blockNumber, 123_456);
    }

    // ───────────────────────────── afterSwap: anchor ─────────────────────────────

    function test_anchorReadThroughAStateViewLikeContract() public {
        vm.prank(owner);
        hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));

        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();

        (uint160 anchorPrice, int24 anchorTick,,) = manager.getSlot0(anchorId);
        assertEq(d.sqrtPriceAnchor, anchorPrice, "anchor sqrtPrice");
        assertEq(d.tickAnchor, anchorTick, "anchor tick");
        assertEq(d.tickAnchor, ANCHOR_TICK);
        assertEq(d.sqrtPriceAnchor, TickMath.getSqrtPriceAtTick(ANCHOR_TICK));
        assertSelfState(d);
    }

    function test_anchorPoolIdIsWhatIsAsked() public {
        // Point at this hook's own pool through the view: the anchor fields must equal the self fields.
        vm.prank(owner);
        hook.setAnchor(address(anchorView), PoolId.unwrap(id));
        vm.recordLogs();
        swapper.swap(key, false, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, d.sqrtPriceSelf);
        assertEq(d.tickAnchor, d.tickSelf);
    }

    function test_anchorNegativeTickIsSignExtended() public {
        FixedAnchor fixedAnchor = new FixedAnchor(4295128739, -887_000);
        vm.prank(owner);
        hook.setAnchor(address(fixedAnchor), bytes32(uint256(1)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 4295128739);
        assertEq(d.tickAnchor, -887_000);
    }

    function test_anchorThatRevertsDoesNotBlockTheSwap() public {
        RevertingAnchor bad = new RevertingAnchor();
        vm.prank(owner);
        hook.setAnchor(address(bad), PoolId.unwrap(anchorId));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
        assertSelfState(d);
    }

    function test_anchorThatBurnsItsGasCostsTheSwapAtMostTheStipend() public {
        // Baseline: what an ordinary swap costs with no anchor.
        uint256 g = gasleft();
        swapper.swap(key, true, 1 ether);
        uint256 baseline = g - gasleft();

        GasBurningAnchor burner = new GasBurningAnchor();
        vm.prank(owner);
        hook.setAnchor(address(burner), PoolId.unwrap(anchorId));

        vm.recordLogs();
        g = gasleft();
        swapper.swap{gas: 300_000}(key, true, 1 ether);
        uint256 used = g - gasleft();
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
        assertSelfState(d);
        assertLt(used, baseline + 60_000, "the anchor consumed more than its stipend");
    }

    function test_anchorWithShortAnswerReadsAsZero() public {
        ShortAnchor short = new ShortAnchor();
        vm.prank(owner);
        hook.setAnchor(address(short), PoolId.unwrap(anchorId));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    function test_anchorWithoutCodeReadsAsZero() public {
        vm.prank(owner);
        hook.setAnchor(makeAddr("eoa"), PoolId.unwrap(anchorId));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    function test_clearingTheAnchorStopsTheRead() public {
        vm.startPrank(owner);
        hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));
        hook.setAnchor(address(0), bytes32(0));
        vm.stopPrank();
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, 0);
        assertEq(d.tickAnchor, 0);
    }

    // ───────────────────────────── afterSwap: pause ─────────────────────────────

    function test_pauseSilencesEmissionButNeverBlocksSwaps() public {
        vm.prank(owner);
        hook.setPaused(true);

        uint256 ethBefore = address(swapper).balance;
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        assertEq(poolDataLogs().length, 0, "paused: nothing emitted");
        assertEq(ethBefore - address(swapper).balance, 1 ether, "the swap still executed");

        vm.prank(owner);
        hook.setPaused(false);
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        assertEq(poolDataLogs().length, 1, "resumed");
    }

    function test_pausedHookSkipsTheAnchorCall() public {
        RevertingAnchor bad = new RevertingAnchor();
        vm.startPrank(owner);
        hook.setAnchor(address(bad), PoolId.unwrap(anchorId));
        hook.setPaused(true);
        vm.stopPrank();
        vm.expectCall(address(bad), abi.encodeWithSelector(bytes4(0xc815641c), PoolId.unwrap(anchorId)), 0);
        swapper.swap(key, true, 1 ether);
    }

    // ───────────────────────────── afterSwap: unit, as the manager ─────────────────────────────

    function test_afterSwapFeeUsesThePaidSide() public {
        // zeroForOne = false pays currency1; amount0 is what it received and must not count.
        vm.recordLogs();
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) =
            hook.afterSwap(address(swapper), key, SwapParams(false, 1_000_000, 0), toBalanceDelta(999, -1_000_000), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0, "no delta ever");
        Data memory d = onlyPoolData();
        assertEq(d.feeAmount, 1_000_000 * uint256(FEE) / 1_000_000);
        assertEq(d.feeAmount, 12_500);
        assertEq(d.swapAmount, 1_000_000);
        assertFalse(d.zeroForOne);
    }

    function test_afterSwapWithNothingPaidReportsZeroFee() public {
        vm.recordLogs();
        vm.prank(address(manager));
        hook.afterSwap(address(swapper), key, SwapParams(true, -1, 0), toBalanceDelta(0, 0), "");
        assertEq(onlyPoolData().feeAmount, 0);
    }

    function test_afterSwapReadsTheRecordedPool() public {
        // The pool read is the one recorded at initialization, never one named by the key passed in.
        vm.recordLogs();
        vm.prank(address(manager));
        hook.afterSwap(address(swapper), anchorKey, SwapParams(true, -1_000_000, 0), toBalanceDelta(-1_000_000, 0), "");
        Data memory d = onlyPoolData();
        assertSelfState(d);
        assertEq(d.liquidity, LIQUIDITY, "the launch pool's liquidity, not the anchor pool's zero");
        assertEq(d.feeAmount, 12_500, "the launch pool's LP fee");
    }

    // ───────────────────────────── no fee, no delta, no custody ─────────────────────────────

    function test_hookTakesNothingAndHoldsNothing() public {
        uint256 managerEth = address(manager).balance;
        uint256 managerTok = token.balanceOf(address(manager));
        uint256 swapperEth = address(swapper).balance;
        uint256 swapperTok = token.balanceOf(address(swapper));

        BalanceDelta delta = swapper.swap(key, true, 1 ether);

        assertEq(swapperEth - address(swapper).balance, 1 ether, "swapper paid exactly the input");
        assertEq(token.balanceOf(address(swapper)) - swapperTok, uint256(uint128(delta.amount1())), "got the output");
        assertEq(address(manager).balance - managerEth, 1 ether, "the manager kept all of it");
        assertEq(managerTok - token.balanceOf(address(manager)), uint256(uint128(delta.amount1())));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(0)).toId()), 0, "no ETH claims");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()), 0, "no token claims");
    }

    function test_hookHasNoReceiveOrFallback() public {
        (bool ok,) = address(hook).call{value: 1 wei}("");
        assertFalse(ok, "accepts ETH");
        (ok,) = address(hook).call(abi.encodeWithSignature("nothing()"));
        assertFalse(ok, "answers unknown selectors");
    }

    // ───────────────────────────── the launch factory's lifecycle ─────────────────────────────

    function test_factoryCollectsFeesWithAZeroLiquidityChange() public {
        swapper.swap(key, true, 10 ether);
        swapper.swap(key, false, 10 ether);
        int24 lower = TickMath.minUsableTick(SPACING);
        int24 upper = TickMath.maxUsableTick(SPACING);
        BalanceDelta collected = lp.modify(key, lower, upper, 0);
        assertGt(collected.amount0(), 0, "ETH fees accrued");
        assertGt(collected.amount1(), 0, "token fees accrued");
        assertApproxEqRel(uint256(uint128(collected.amount0())), 10 ether * uint256(FEE) / 1_000_000, 1e15);
    }

    function test_liquidityCanBeRemoved() public {
        int24 lower = TickMath.minUsableTick(SPACING);
        int24 upper = TickMath.maxUsableTick(SPACING);
        lp.modify(key, lower, upper, -int256(uint256(LIQUIDITY)));
        assertEq(manager.getLiquidity(id), 0);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_exactInputSwapsReportConsistentData(uint256 amountIn, bool zeroForOne, bool anchored) public {
        amountIn = bound(amountIn, 1e6, 1e20);
        if (anchored) {
            vm.prank(owner);
            hook.setAnchor(address(anchorView), PoolId.unwrap(anchorId));
        }
        vm.recordLogs();
        BalanceDelta delta = swapper.swap(key, zeroForOne, amountIn);
        Data memory d = onlyPoolData();

        assertSelfState(d);
        assertEq(d.swapAmount, -int256(amountIn));
        assertEq(d.zeroForOne, zeroForOne);
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        assertEq(uint256(uint128(-paid)), amountIn);
        assertEq(d.feeAmount, amountIn * FEE / 1_000_000);
        assertEq(d.liquidity, LIQUIDITY);
        if (anchored) {
            assertEq(d.tickAnchor, ANCHOR_TICK);
            assertEq(d.sqrtPriceAnchor, TickMath.getSqrtPriceAtTick(ANCHOR_TICK));
        } else {
            assertEq(d.sqrtPriceAnchor, 0);
            assertEq(d.tickAnchor, 0);
        }
    }

    function testFuzz_exactOutputSwapsReportFeeOnWhatWasPaid(uint256 amountOut, bool zeroForOne) public {
        amountOut = bound(amountOut, 1e6, 1e19);
        vm.recordLogs();
        BalanceDelta delta = swapper.swapExact(key, zeroForOne, int256(amountOut));
        Data memory d = onlyPoolData();
        assertSelfState(d);
        assertEq(d.swapAmount, int256(amountOut));
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        assertLt(paid, 0);
        assertEq(d.feeAmount, uint256(uint128(-paid)) * FEE / 1_000_000);
    }

    function testFuzz_anchorValuesPassThroughUnchanged(uint160 sqrtPrice, int24 tick) public {
        FixedAnchor fixedAnchor = new FixedAnchor(sqrtPrice, tick);
        vm.prank(owner);
        hook.setAnchor(address(fixedAnchor), bytes32(uint256(42)));
        vm.recordLogs();
        swapper.swap(key, true, 1 ether);
        Data memory d = onlyPoolData();
        assertEq(d.sqrtPriceAnchor, sqrtPrice);
        assertEq(d.tickAnchor, tick);
    }

    function testFuzz_onlyTheOwnerAdministers(address caller) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setAnchor(caller, bytes32(0));
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.setPaused(true);
        vm.expectRevert(SiphonHook.NotOwner.selector);
        hook.transferOwnership(caller);
        vm.stopPrank();
    }
}
