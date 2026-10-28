// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SIPHON launch token
/// @notice Fixed-supply ERC-20: 1,000,000,000 SIPH at 18 decimals, minted once to the deployer (the
/// launch factory). No owner, mint, pause, blocklist, fee or upgrade path exists.
contract SiphonToken is ERC20 {
    /// @notice The whole supply, in minor units.
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("SIPHON", "SIPH") {
        _mint(msg.sender, SUPPLY);
    }
}
