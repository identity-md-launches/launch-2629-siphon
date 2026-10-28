// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared assertions about who administers a launched contract.
/// @dev The launch factory deploys every contract, so `msg.sender` in a constructor is the factory,
/// and IMD's launch wallet is `tx.origin`. Neither may end up as the owner: IMD never owns or runs a
/// launch's contracts.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` while a contract is deployed.
    address internal constant ORIGIN_PROBE = address(uint160(0x071C));

    /// @notice Fails if `target` reports an owner that is the factory, the origin probe, the harness
    /// itself or the zero address. A contract with no `owner()` has nothing to check.
    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return;
        address owner = abi.decode(ret, (address));
        assertTrue(
            owner != factory, string.concat(name, " is owned by the launch factory: take the owner as \"$owner\"")
        );
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
        assertTrue(owner != address(this), string.concat(name, " is owned by the deploying harness"));
        assertTrue(owner != address(0), string.concat(name, " has no owner but still exposes owner()"));
    }
}
