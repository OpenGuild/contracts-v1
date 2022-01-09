// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "./external/BaseUpgradeablePausable.sol";
import "./GovernanceToken.sol";
import "./WarrantToken.sol";

contract ProtocolConfig is BaseUpgradeablePausable {
    // OpenGuild's take rate is 5%
    uint256 public constant PROTOCOL_TAKE_RATE = 500;
    // Pool manager take rate is 0.3%
    uint256 public constant POOL_MANAGER_TAKE_RATE = 30;
    uint256 public constant TAKE_RATE_PRECISION = 10000;

    // Addresses for contracts
    mapping(uint256 => address) public addresses;

    // Mapping between valid aggregate pool addresses and whether they are alive or not
    mapping(address => bool) public validAggregatePools;

    // Mapping between valid individual pool addresses and whether they are alive or not
    mapping(address => bool) public validIndividualPools;

    event AddressUpdated(
        address owner,
        uint256 index,
        address oldValue,
        address newValue
    );
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

    function initialize(address _owner, address _treasury) public initializer {
        require(_owner != address(0), "Owner address cannot be empty");
        require(_treasury != address(0), "Treasury address cannot be empty");

        __BaseUpgradeablePausable__init(_owner);
        setTreasuryAddress(_treasury);
    }

    function getAddress(uint256 index) public view returns (address) {
        return addresses[index];
    }

    function setGovernanceTokenAddress(address newGovernanceTokenAddress)
        external
        onlyAdmin
    {
        uint256 key = uint256(Addresses.GovernanceToken);
        addresses[key] = newGovernanceTokenAddress;
    }

    function setWarrantTokenAddress(address newWarrantTokenAddress)
        external
        onlyAdmin
    {
        uint256 key = uint256(Addresses.WarrantToken);
        addresses[key] = newWarrantTokenAddress;
    }

    function setTreasuryAddress(address newTreasuryAddress) public onlyAdmin {
        uint256 key = uint256(Addresses.Treasury);
        addresses[key] = newTreasuryAddress;
    }

    function getGovernanceTokenContract()
        external
        view
        returns (GovernanceToken)
    {
        return GovernanceToken(getAddress(uint256(Addresses.GovernanceToken)));
    }

    function getWarrantTokenAddress() public view returns (address) {
        return getAddress(uint256(Addresses.WarrantToken));
    }

    function getTreasuryAddress() external view returns (address) {
        return getAddress(uint256(Addresses.Treasury));
    }

    function addAggregatePool(address pool) external onlyAdmin {
        require(
            isContract(pool),
            "Can only add pool addresses as an aggregate pool"
        );

        validAggregatePools[pool] = true;
    }

    function removeAggregatePool(address pool) external onlyAdmin {
        require(
            isValidAggregatePool(pool),
            "Can only remove valid aggregate pools"
        );

        validAggregatePools[pool] = false;
    }

    function isValidAggregatePool(address pool) public view returns (bool) {
        return validAggregatePools[pool];
    }

    function addIndividualPool(address pool) external onlyAdmin {
        require(
            isContract(pool),
            "Can only add pool addresses as an individual pool"
        );

        validIndividualPools[pool] = true;
    }

    function removeIndividualPool(address pool) external onlyAdmin {
        require(
            isValidIndividualPool(pool),
            "Can remove valid individual pools"
        );

        validIndividualPools[pool] = false;
    }

    function isValidIndividualPool(address pool) public view returns (bool) {
        return validIndividualPools[pool];
    }

    function getProtocolTakeRate() external pure returns (uint256) {
        return PROTOCOL_TAKE_RATE;
    }

    function getPoolManagerTakeRate() external pure returns (uint256) {
        return POOL_MANAGER_TAKE_RATE;
    }

    function getTakeRatePrecision() external pure returns (uint256) {
        return TAKE_RATE_PRECISION;
    }
}
