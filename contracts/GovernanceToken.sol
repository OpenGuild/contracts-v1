// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/presets/ERC20PresetMinterPauserUpgradeable.sol";

/**
 * @title GovernanceToken
 * @dev This contract refers to the OpenGuild token.
 */
contract GovernanceToken is ERC20PresetMinterPauserUpgradeable {
    function initialize(string memory name, string memory symbol)
        public
        override
        initializer
    {
        __ERC20PresetMinterPauser_init(name, symbol);
    }
}
