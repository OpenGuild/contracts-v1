// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./InvestmentQueue.sol";
import "./WarrantToken.sol";
import "./ProtocolConfig.sol";
import "./BasePool.sol";
import "./IndividualPool.sol";

/**
    An AggregatePool is a pool where investors can invest cryptocurrency into multiple IndividualPools and 
    claim dividends from each.

    An OGISP is initialized with:
      - a pool token address: the token denominating investments, withdrawals, and contributions
      - a reward token address: the token the investor receives as a reward
      - a maximum investment amount: the maximum amount that an investor can contribute at a time
      - a list of individual pool addresses: the individual pools that are associated with an aggregate pool

    Investor capital is deployed FIFO. To prevent one investor from taking up most of the proceeds, we
    implement a max investment.
 */

contract AggregatePool is BasePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    string public constant name = "AggregatePool";

    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    // --- Pool state ----------------
    // Maximum investment that an investor could make at a given time
    uint256 public maxInvestment;

    // individual pool address -> % of investments, map of individual pool address to percentage of investments
    mapping(address => uint256) public individualPoolAllocations;

    // array of indvidual pool addresses that are associated with this aggregate pool
    address[] public individualPoolAddresses;

    // How much an allocation could be off by (margin of error in percentage terms: ALLOCATION_MARGIN_OF_ERROR/PERCENTAGE_DECIMAL)
    uint256 public constant ALLOCATION_MARGIN_OF_ERROR = 10**4;

    event SetPoolAllocations(address indexed poolAddress);

    // https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        address _owner,
        ProtocolConfig _config,
        IERC20Upgradeable _poolToken,
        uint256 _maxInvestment,
        address[] memory _individualPoolAddresses
    ) public initializer {
        // initial variables
        maxInvestment = _maxInvestment;
        individualPoolAddresses = _individualPoolAddresses;

        __BasePool__init(
            _owner,
            _config,
            _poolToken,
            ProtocolConfig.PoolType.AggregatePool
        );

        _setRoleAdmin(POOL_MANAGER_ROLE, OWNER_ROLE);
        _setupRole(POOL_MANAGER_ROLE, _owner);
    }

    function _absoluteDifference(uint256 a, uint256 b)
        private
        pure
        returns (uint256)
    {
        if (a > b) {
            return a - b;
        }
        return b - a;
    }

    /*
        Sets the pool allocations, or percentages of investments that should go into
        each pool

        If a client wants to completely remove an individual pool from the allocation, the address's corresponding percentage 
        should explicitly be set to 0. This isn't strictly necessary, as the source of truth of which individual pools are
        given allocation in this aggregate pool is the individualPoolAddresses array, which is overridden by the input
        on every function call.
    */
    function setPoolAllocations(
        address[] memory newPoolAddresses,
        uint256[] memory newPercentages
    ) external onlyRole(POOL_MANAGER_ROLE) {
        require(
            newPoolAddresses.length > 0,
            "Individual pool address length cannot be 0"
        );
        require(
            newPoolAddresses.length == newPercentages.length,
            "The number of pools and newPercentages are different"
        );

        bool areAllValidIndividualPools = true;
        bool allUseSamePoolToken = true;
        uint256 sum = 0;

        for (uint256 i = 0; i < newPoolAddresses.length; i++) {
            address poolAddress = newPoolAddresses[i];
            if (!config.isValidIndividualPool(poolAddress)) {
                areAllValidIndividualPools = false;
                break;
            }

            IndividualPool pool = IndividualPool(poolAddress);

            if (address(pool.poolToken()) != address(poolToken)) {
                allUseSamePoolToken = false;
                break;
            }
            uint256 percentage = newPercentages[i];
            sum += percentage;
        }

        uint256 sumDifference = _absoluteDifference(
            100 * PERCENTAGE_DECIMAL,
            sum
        );

        // Round up the sum if the calculated sum is off by less than
        // ALLOCATION_MARGIN_OF_ERROR
        if (sumDifference <= ALLOCATION_MARGIN_OF_ERROR) {
            sum += sumDifference;
        }

        require(
            sum == 100 * PERCENTAGE_DECIMAL,
            "Pool allocations must add up to 100"
        );

        require(
            areAllValidIndividualPools,
            "Invalid individual pool found in newPoolAddresses"
        );
        require(
            allUseSamePoolToken,
            "All individual pools must use the same pool token as this aggregate pool"
        );

        // Set individualPoolAddresses to parameter;
        individualPoolAddresses = newPoolAddresses;
        for (uint256 i = 0; i < newPoolAddresses.length; i++) {
            address poolAddress = newPoolAddresses[i];
            uint256 percentage = newPercentages[i];
            individualPoolAllocations[poolAddress] = percentage;
        }

        // Round up the first percentage if the calculated sum is off by less than
        // ALLOCATION_MARGIN_OF_ERROR
        if (sumDifference <= ALLOCATION_MARGIN_OF_ERROR) {
            individualPoolAllocations[
                individualPoolAddresses[0]
            ] += sumDifference;
        }

        emit SetPoolAllocations(address(this));
    }

    function invest(uint256 amount) external onlyRole(INVESTOR_ROLE) {
        require(amount > 0, "You must invest more than 0");

        require(
            poolToken.balanceOf(_msgSender()) >= amount,
            "You don't have enough tokens to invest"
        );
        require(
            amount <= maxInvestment,
            "Amount invested exceeds the maximum investment"
        );
        uint256 tokenId = warrantToken.mint(
            _msgSender(),
            address(this),
            poolType
        );
        address investor = _msgSender();
        poolToken.safeTransferFrom(investor, address(this), amount);
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            uint256 poolAmount = _multiplyByAllocationPercentage(
                poolAddress,
                amount
            );
            if (poolAmount > 0) {
                poolToken.transfer(poolAddress, poolAmount);
                IndividualPool individualPool = IndividualPool(poolAddress);
                individualPool.investFromAggregatePool(
                    poolAmount,
                    tokenId,
                    investor,
                    address(this)
                );
            }
        }
        emit Invest(tokenId, investor, amount);
    }

    function claim() external onlyRole(INVESTOR_ROLE) {
        require(
            individualPoolAddresses.length > 0,
            "There are no individual pools associated with this aggregate pool"
        );

        address claimer = _msgSender();
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);

            individualPool.claimFromAggregatePool(claimer);
        }
    }

    function removeUndeployedCapital(uint256[] memory tokenIds)
        external
        onlyRole(INVESTOR_ROLE)
    {
        require(
            individualPoolAddresses.length > 0,
            "No undeployed capital to remove"
        );
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(
                warrantToken.getPool(tokenId) == address(this),
                "This warrant token was not minted from this pool"
            );

            require(
                warrantToken.ownerOf(tokenId) == _msgSender(),
                "This token does not belong to the caller"
            );

            address remover = _msgSender();
            uint256 burnTarget = 0;
            for (uint256 j = 0; j < individualPoolAddresses.length; j++) {
                address poolAddress = individualPoolAddresses[j];
                IndividualPool individualPool = IndividualPool(poolAddress);

                individualPool.removeUndeployedFromAggregatePool(
                    remover,
                    tokenId
                );
                if (individualPool.tokenDeployedAmount(tokenId) == 0) {
                    burnTarget += 1;
                }
            }
            if (burnTarget == individualPoolAddresses.length) {
                warrantToken.burn(tokenId);
            }
        }
    }

    // Returns the sum of all dividends returned to this aggregate pool
    function getCumulativeDividends() public view override returns (uint256) {
        uint256 totalReturned;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalReturned += individualPool.getCumulativeDividendsForPool(
                address(this)
            );
        }
        return totalReturned;
    }

    // Returns the sum of all investments deployed in this aggregate pool
    function getCumulativeDeployedAmount()
        public
        view
        override
        returns (uint256)
    {
        uint256 totalDeployed;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalDeployed += individualPool.getCumulativeDeployedAmountForPool(
                address(this)
            );
        }
        return totalDeployed;
    }

    // Returns amount multiplied by allocation percentage of the individual pool passed in
    function _multiplyByAllocationPercentage(
        address individualPool,
        uint256 amount
    ) private view returns (uint256) {
        return
            (individualPoolAllocations[individualPool] * amount) /
            (100 * PERCENTAGE_DECIMAL);
    }

    function setPoolManager(address newPoolManagerAddress)
        external
        onlyRole(OWNER_ROLE)
    {
        address poolManagerAddress = getPoolManager();

        revokeRole(POOL_MANAGER_ROLE, poolManagerAddress);
        grantRole(POOL_MANAGER_ROLE, newPoolManagerAddress);
        require(
            getRoleMemberCount(POOL_MANAGER_ROLE) == 1,
            "Only one pool manager could be set at at time!"
        );
    }

    function getPoolManager() public view returns (address) {
        return getRoleMember(POOL_MANAGER_ROLE, 0);
    }

    // Returns a warrant token's cash on cash return
    function getReturnsForToken(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 dividends;
        uint256 deployedAmount;

        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            dividends += individualPool.getTokenTotalDividends(tokenId);
            deployedAmount += individualPool.getTokenDeployedAmount(tokenId);
        }

        if (deployedAmount == 0) {
            return 0;
        }

        return (100 * PERCENTAGE_DECIMAL * dividends) / deployedAmount;
    }

    // Dividends are weighted pro-rata by an investor's contribution
    function getTokenTotalDividends(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 tokenTotalDividends;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            tokenTotalDividends += individualPool.getTokenTotalDividends(
                tokenId
            );
        }
        return tokenTotalDividends;
    }

    // Dividends are weighted pro-rata by an investor's contribution
    function getTokenUnclaimedDividends(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 tokenUnclaimedDividends;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            tokenUnclaimedDividends += individualPool
                .getTokenUnclaimedDividends(tokenId);
        }
        return tokenUnclaimedDividends;
    }

    // Return cumulative deployed amount by warrant token ID
    function getTokenDeployedAmount(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 tokenTotalDeployed;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            tokenTotalDeployed += individualPool.getTokenDeployedAmount(
                tokenId
            );
        }
        return tokenTotalDeployed;
    }

    // Return cumulative undeployed amount by warrant token ID
    function getUndeployedAmountForWarrantToken(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 warrantTokenTotalUndeployed;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            warrantTokenTotalUndeployed += individualPool
                .getUndeployedAmountForWarrantToken(tokenId);
        }
        return warrantTokenTotalUndeployed;
    }

    function getIndividualAddressesLength() external view returns (uint256) {
        return individualPoolAddresses.length;
    }

    // Return total undeployed amount aggregated across all individual pools
    function getTotalUndeployedAmount()
        external
        view
        override
        returns (uint256)
    {
        uint256 totalUndeployedAmount;
        for (uint256 i = 0; i < individualPoolAddresses.length; i++) {
            address poolAddress = individualPoolAddresses[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalUndeployedAmount += individualPool.getTotalUndeployedAmount();
        }
        return totalUndeployedAmount;
    }
}
