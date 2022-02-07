// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "./external/BaseUpgradeablePausable.sol";
import "./GovernanceToken.sol";
import "./WarrantToken.sol";

contract ProtocolConfig is BaseUpgradeablePausable {
    // OpenGuild's take rate is 5%
    uint256 public constant PROTOCOL_TAKE_RATE = 500;
    // Set pool manager take rate to 0 in v1
    uint256 public constant POOL_MANAGER_TAKE_RATE = 0;
    uint256 public constant TAKE_RATE_PRECISION = 10000;

    // assigned key => addresses for contracts
    mapping(uint256 => address) public addresses;

    // aggregate pool addresses => aggregate pool address's validity
    mapping(address => bool) public validAggregatePools;

    // individual pool addresses => individual pool address's validity
    mapping(address => bool) public validIndividualPools;

    // DO NOT CHANGE EXISTING VALUES; APPEND ONLY
    enum Addresses {
        GovernanceToken,
        ProtocolConfig,
        WarrantToken,
        Treasury
    }

    // Type of pool
    // DO NOT CHANGE EXISTING VALUES; APPEND ONLY
    enum PoolType {
        AggregatePool,
        IndividualPool
    }

    /**
     * @notice Run only once, on initialization
     * @param _owner The address of who should have the "OWNER_ROLE" of this contract
     * @param _treasury The address of the OpenGuild treasury
     */
    function initialize(address _owner, address _treasury) public initializer {
        require(_owner != address(0), "Owner address cannot be empty");
        require(_treasury != address(0), "Treasury address cannot be empty");

        __BaseUpgradeablePausable__init(_owner);
        setTreasuryAddress(_treasury);
    }

    /**
     * @return The address at a given index
     * @param index The index of the address
     */
    function getAddress(uint256 index) public view returns (address) {
        return addresses[index];
    }

    /**
     * @notice Sets the governance token address in the addresses mapping
     * @notice Only callable by the admin
     * @param newGovernanceTokenAddress The governance token address
     */
    function setGovernanceTokenAddress(address newGovernanceTokenAddress)
        external
        onlyAdmin
    {
        uint256 key = uint256(Addresses.GovernanceToken);
        addresses[key] = newGovernanceTokenAddress;
    }

    /**
     * @notice Sets the warrant token address in the addresses mapping
     * @notice Only callable by the admin
     * @param newWarrantTokenAddress The warrant token address
     */
    function setWarrantTokenAddress(address newWarrantTokenAddress)
        external
        onlyAdmin
    {
        uint256 key = uint256(Addresses.WarrantToken);
        addresses[key] = newWarrantTokenAddress;
    }

    /**
     * @notice Sets the treasury address in the addresses mapping
     * @notice Only callable by the admin
     * @param newTreasuryAddress The treasury address
     */
    function setTreasuryAddress(address newTreasuryAddress) public onlyAdmin {
        uint256 key = uint256(Addresses.Treasury);
        addresses[key] = newTreasuryAddress;
    }

    /// @return The protocol's governance token contract
    function getGovernanceTokenContract()
        external
        view
        returns (GovernanceToken)
    {
        return GovernanceToken(getAddress(uint256(Addresses.GovernanceToken)));
    }

    /// @return The protocol's warrant token address
    function getWarrantTokenAddress() public view returns (address) {
        return getAddress(uint256(Addresses.WarrantToken));
    }

    /// @return The OpenGuild treasury address
    function getTreasuryAddress() external view returns (address) {
        return getAddress(uint256(Addresses.Treasury));
    }

    /**
     * @notice Adds the given aggregate pool to the array of validAggregatePools
     * @notice Only callable by the admin
     * @param pool An aggregate pool that the protocol adds
     */
    function addAggregatePool(address pool) external onlyAdmin {
        require(
            isContract(pool),
            "Can only add pool addresses as an aggregate pool"
        );

        validAggregatePools[pool] = true;
    }

    /**
     * @notice Removes the given aggregate pool from the array of validAggregatePools
     * @notice Only callable by the admin
     * @param pool An aggregate pool that the protocol removes
     */
    function removeAggregatePool(address pool) external onlyAdmin {
        require(
            isValidAggregatePool(pool),
            "Can only remove valid aggregate pools"
        );

        validAggregatePools[pool] = false;
    }

    /**
     * @return Whether or not the aggregate pool is valid
     * @param pool The aggregate pool being checked
     */
    function isValidAggregatePool(address pool) public view returns (bool) {
        return validAggregatePools[pool];
    }

    /**
     * @notice Adds the given individual pool to the array of validIndividualPools
     * @notice Only callable by the admin
     * @param pool An individual pool that the protocol adds
     */
    function addIndividualPool(address pool) external onlyAdmin {
        require(
            isContract(pool),
            "Can only add pool addresses as an individual pool"
        );

        validIndividualPools[pool] = true;
    }

    /**
     * @notice Removes the given individual pool from the array of validIndividualPools
     * @notice Only callable by the admin
     * @param pool An individual pool that the protocol removes
     */
    function removeIndividualPool(address pool) external onlyAdmin {
        require(
            isValidIndividualPool(pool),
            "Can only remove valid individual pools"
        );

        validIndividualPools[pool] = false;
    }

    /**
     * @return Whether or not the individual pool is valid
     * @param pool The individual pool being checked
     */
    function isValidIndividualPool(address pool) public view returns (bool) {
        return validIndividualPools[pool];
    }

    /// @return The protocol wide take rate
    function getProtocolTakeRate() external pure returns (uint256) {
        return PROTOCOL_TAKE_RATE;
    }

    /// @return The protocol wide pool manager take rate
    function getPoolManagerTakeRate() external pure returns (uint256) {
        return POOL_MANAGER_TAKE_RATE;
    }

    /// @return The protocol wide take rate precision
    function getTakeRatePrecision() external pure returns (uint256) {
        return TAKE_RATE_PRECISION;
    }
}
