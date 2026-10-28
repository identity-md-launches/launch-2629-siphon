// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SiphonHook} from "../src/SiphonHook.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Rehearsal deployment of the token and the hook. The IMD launch factory performs the real
/// launch from the attested bytecode; this script exists so the same steps can be dry-run on a fork
/// or a local node, and so tests can exercise the deployment logic directly.
contract DeploySiphon is Script {
    /// @dev Where `forge script --broadcast` sends a salted `new`: the deterministic CREATE2 deployer.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP;

    /// @notice The salt and resulting address that place the hook on its permission bits when
    /// deployed by `deployer` with CREATE2.
    function mineSalt(address deployer, IPoolManager poolManager, address owner_)
        public
        pure
        returns (bytes32 salt, address hookAddress)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(SiphonHook).creationCode, abi.encode(poolManager, owner_)));
        for (uint256 i = 0; i < 1_000_000; i++) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initHash)))));
            if (HookFlags.matches(predicted, HOOK_FLAGS)) return (bytes32(i), predicted);
        }
        revert("no salt found");
    }

    function deployToken() public returns (SiphonToken) {
        return new SiphonToken();
    }

    function deployHook(IPoolManager poolManager, address owner_, bytes32 salt) public returns (SiphonHook) {
        return new SiphonHook{salt: salt}(poolManager, owner_);
    }

    /// @notice Reads POOL_MANAGER and OWNER from the environment and deploys both contracts.
    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner_ = vm.envAddress("OWNER");
        (bytes32 salt,) = mineSalt(CREATE2_DEPLOYER, poolManager, owner_);
        vm.startBroadcast();
        deployToken();
        deployHook(poolManager, owner_, salt);
        vm.stopBroadcast();
    }
}
