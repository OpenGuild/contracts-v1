// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/**
 * @title PauserPausable, audited by Certik (https://github.com/goldfinch-eng/goldfinch-contracts/blob/main/v2.0/Certik-Goldfinch-Audit-Report-2021-8-26.pdf)
 * @notice Inheriting from OpenZeppelin's Pausable contract, this does small
 *  augmentations to make it work with a PAUSER_ROLE, leveraging the AccessControl contract.
 *  It is meant to be inherited.
 * @author Goldfinch
 */

contract PauserPausable is
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // solhint-disable-next-line func-name-mixedcase
    function __PauserPausable__init() public initializer {
        __Pausable_init_unchained();
    }

    /**
     * @dev Pauses all functions guarded by Pause
     *
     * See {Pausable-_pause}.
     *
     * Requirements:
     *
     * - the caller must have the PAUSER_ROLE.
     */

    function pause() public onlyPauserRole {
        _pause();
    }

    /**
     * @dev Unpauses the contract
     *
     * See {Pausable-_unpause}.
     *
     * Requirements:
     *
     * - the caller must have the Pauser role
     */
    function unpause() public onlyPauserRole {
        _unpause();
    }

    modifier onlyPauserRole() {
        require(
            hasRole(PAUSER_ROLE, _msgSender()),
            "Must have pauser role to perform this action"
        );
        _;
    }
}
