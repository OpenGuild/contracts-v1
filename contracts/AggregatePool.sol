// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./WarrantToken.sol";
import "./ProtocolConfig.sol";
import "./BasePool.sol";
import "./IndividualPool.sol";

/**
  * @title OpenGuild's Aggregate Pool contract
  * @notice An AggregatePool is a pool where investors can invest cryptocurrency into multiple IndividualPools and 
    claim dividends from each.
  */

contract AggregatePool is BasePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // --- IAM roles ------------------
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    // --- Pool state ----------------
    // individual pool address => % of investments, map of individual pool address to allocated percentage of investments
    mapping(address => uint256) public individualPoolAllocations;

    // array of indvidual pool addresses that are currently associated with this aggregate pool
    address[] public currentIndividualPools;

    // array of all indvidual pool addresses that have been associated with this aggregate pool
    /// @dev This array is accessed when investors need to access information and attempt to claim from individual pools no longer in currentIndividualPools
    address[] public allIndividualPools;

    // maximum difference allowed between pool percentage allocations and 100 (margin of error in percentage terms: ALLOCATION_MARGIN_OF_ERROR/PERCENTAGE_DECIMAL)
    uint256 public constant ALLOCATION_MARGIN_OF_ERROR = 10**4;

    // The cap of investments accepted by this pool
    uint256 public poolInvestmentLimit;

    // Maximum investment that an investor could make in the entire pool
    uint256 public investorInvestmentLimit;

    event SetPoolAllocations(address indexed poolAddress);

    /**
     * @notice Run only once, on initialization
     * @param _owner The address that is assigned the "OWNER_ROLE" of this contract
     * @param _config The address of the OpenGuild ProtocolConfig contract
     * @param _poolToken The ERC20 token denominating investments, withdrawals and contributions
     * @param _currentIndividualPools The individual pools associated with this aggregate pool
     * @param _currentPercentages The percentage allocations associated with this aggregate pool
     * @param _poolInvestmentLimit The cap of investments accepted by this pool
     * @param _investorInvestmentLimit The maximum investment that an investor could make in the entire pool
     */
    function initialize(
        address _owner,
        ProtocolConfig _config,
        IERC20Upgradeable _poolToken,
        address[] memory _currentIndividualPools,
        uint256[] memory _currentPercentages,
        uint256 _poolInvestmentLimit,
        uint256 _investorInvestmentLimit
    ) public initializer {
        require(
            _currentIndividualPools.length == _currentPercentages.length,
            "The number of pools and percentages are different"
        );

        // initialize variables
        poolInvestmentLimit = _poolInvestmentLimit;
        investorInvestmentLimit = _investorInvestmentLimit;
        currentIndividualPools = _currentIndividualPools;

        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address pool = currentIndividualPools[i];
            individualPoolAllocations[pool] = _currentPercentages[i];
        }

        __BasePool__init(
            _owner,
            _config,
            _poolToken,
            ProtocolConfig.PoolType.AggregatePool
        );
        _setRoleAdmin(INVESTOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, OWNER_ROLE);
        _setupRole(POOL_MANAGER_ROLE, _owner);
    }

    /**
     * @notice Returns the absolute difference between a and b
     * @param a Number to subtract
     * @param b Number to subtract
     */
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

    /**
     * @notice Sets the percentage of investments that should go into each pool
     * @notice Only callable by pool manager
     * @param newIndividualPools New individual pool addresses to add to the aggregate pool's allocations
     * @param newPercentages Corresponding allocation percentages to the individual pool addresses
     */
    function setPoolAllocations(
        address[] memory newIndividualPools,
        uint256[] memory newPercentages
    ) external onlyRole(POOL_MANAGER_ROLE) {
        require(
            newIndividualPools.length > 0,
            "Individual pool address length cannot be 0"
        );
        require(
            newIndividualPools.length == newPercentages.length,
            "The number of pools and newPercentages are different"
        );

        bool areAllValidIndividualPools = true;
        bool allUseSamePoolToken = true;
        uint256 sum = 0;

        for (uint256 i = 0; i < newIndividualPools.length; i++) {
            address poolAddress = newIndividualPools[i];
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
            // This check makes sure a pool is not double added to allIndividualPools
            require(percentage > 0, "You cannot set a pool's allocation to 0");
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
            allUseSamePoolToken,
            "All individual pools must use the same pool token as this aggregate pool"
        );

        require(
            areAllValidIndividualPools,
            "Invalid individual pool found in newIndividualPools"
        );

        require(
            sum == 100 * PERCENTAGE_DECIMAL,
            "Pool allocations must add up to 100"
        );

        // Set currentIndividualPools to parameter;
        currentIndividualPools = newIndividualPools;
        for (uint256 i = 0; i < newIndividualPools.length; i++) {
            address poolAddress = newIndividualPools[i];
            if (individualPoolAllocations[poolAddress] == 0) {
                allIndividualPools.push(poolAddress);
            }
            uint256 percentage = newPercentages[i];
            individualPoolAllocations[poolAddress] = percentage;
        }

        // Round up the first percentage by the difference betweeen the calculated sum and ALLOCATION_MARGIN_OF_ERROR
        // sumDifference is always less than ALLOCATION_MARGIN_OF_ERROR from previous checks
        individualPoolAllocations[currentIndividualPools[0]] += sumDifference;

        emit SetPoolAllocations(address(this));
    }

    /**
     * @notice Invests capital into the aggregate pool and distributes investments accordingly to individualPoolAllocations
     * @notice Only callable by an investor
     * @param amount Amount to be invested
     */
    function invest(uint256 amount) external onlyRole(INVESTOR_ROLE) {
        require(
            currentIndividualPools.length > 0,
            "There are no individual pools associated with this pool"
        );

        require(amount > 0, "You must invest more than 0");

        require(
            poolToken.balanceOf(_msgSender()) >= amount,
            "You don't have enough pool tokens to invest"
        );

        require(
            amount +
                getCumulativeDeployedAmount() +
                getTotalUndeployedAmount() <=
                poolInvestmentLimit,
            "This pool has already reached its max investment"
        );

        require(
            amount + totalInvestedAmountForInvestor[_msgSender()] <=
                investorInvestmentLimit,
            "This investor has already invested the max amount for this pool"
        );

        totalInvestedAmountForInvestor[_msgSender()] += amount;

        uint256 warrantTokenId = warrantToken.mint(
            _msgSender(),
            address(this),
            poolType
        );

        address investor = _msgSender();
        poolToken.safeTransferFrom(investor, address(this), amount);
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            uint256 poolAmount = _multiplyByAllocationPercentage(
                poolAddress,
                amount
            );
            poolToken.transfer(poolAddress, poolAmount);
            IndividualPool individualPool = IndividualPool(poolAddress);
            individualPool.investFromAggregatePool(
                poolAmount,
                warrantTokenId,
                investor
            );
        }
        emit Invest(warrantTokenId, investor, amount);
    }

    /**
     * @notice Claim all unclaimed dividends from allIndividualPools
     * @notice Only callable by an investor
     */
    function claim() external onlyRole(INVESTOR_ROLE) {
        require(
            allIndividualPools.length > 0,
            "There are no individual pools associated with this aggregate pool"
        );

        address claimer = _msgSender();
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);

            individualPool.claimFromAggregatePool(claimer);
        }
    }

    /// @return Sum of all dividends returned to this aggregate pool
    function getCumulativeDividends() public view override returns (uint256) {
        uint256 totalReturned;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalReturned += individualPool.getCumulativeDividends();
        }
        return totalReturned;
    }

    /// @return Sum of all investments deployed aggregated across allIndividualPools
    function getCumulativeDeployedAmount()
        public
        view
        override
        returns (uint256)
    {
        uint256 totalDeployed;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalDeployed += individualPool.getCumulativeDeployedAmount();
        }
        return totalDeployed;
    }

    /**
     * @return Amount multiplied by allocation percentage of the individual pool passed in
     * @param individualPool The address of the individual pool's allocation used to calculate pro-rata amount
     * @param amount The amount to be split by pool allocation
     */
    function _multiplyByAllocationPercentage(
        address individualPool,
        uint256 amount
    ) private view returns (uint256) {
        return
            (individualPoolAllocations[individualPool] * amount) /
            (100 * PERCENTAGE_DECIMAL);
    }

    /**
     * @notice Set a new pool investment limit
     * @notice Only callable by the owner
     * @dev There are no checks for the minimum newLimit because if the limit is set to an amount lower than
     * the exisiting capital in the pool, then investors won't be able to make any new investments which is
     * the expected behavior.
     * @param newLimit New pool investment limit
     */
    function setPoolInvestmentLimit(uint256 newLimit)
        external
        onlyRole(OWNER_ROLE)
    {
        poolInvestmentLimit = newLimit;
    }

    /**
     * @notice Set a new investor investment limit
     * @notice Only callable by the owner
     * @dev There are no checks for the minimum newLimit because if the limit is set to an amount lower than
     * an investor's totalInvestedAmountForInvestor, then investors won't be able to make any new investments
     * which is the expected behavior.
     * @param newLimit New investor investment limit
     */
    function setInvestorInvestmentLimit(uint256 newLimit)
        external
        onlyRole(OWNER_ROLE)
    {
        investorInvestmentLimit = newLimit;
    }

    /**
     * @notice Grants all addresses the INVESTOR_ROLE
     * @notice Only callable by the owner
     * @param investors Addresses of the new investors
     */
    function addInvestors(address[] memory investors)
        external
        onlyRole(OWNER_ROLE)
    {
        require(investors.length > 0, "You must add at least one investor");
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            grantRole(INVESTOR_ROLE, investor);
        }
    }

    /**
     * @notice Removes all addresses from the INVESTOR_ROLE
     * @notice Only callable by the owner
     * @param investors Addresses of the removed investors
     */
    function removeInvestors(address[] memory investors)
        external
        onlyRole(OWNER_ROLE)
    {
        require(investors.length > 0, "You must remove at least one investor");
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            revokeRole(INVESTOR_ROLE, investor);
        }
    }

    /**
     * @notice Replace the current pool manager with a new pool manager
     * @notice Only callable by the owner
     * @param newPoolManager Address of the new pool manager
     */
    function setPoolManager(address newPoolManager)
        external
        onlyRole(OWNER_ROLE)
    {
        address currentPoolManager = getPoolManager();

        revokeRole(POOL_MANAGER_ROLE, currentPoolManager);
        grantRole(POOL_MANAGER_ROLE, newPoolManager);
        require(
            getRoleMemberCount(POOL_MANAGER_ROLE) == 1,
            "Only one pool manager could be set at at time!"
        );
    }

    /// @return Address of the pool manager
    function getPoolManager() public view returns (address) {
        return getRoleMember(POOL_MANAGER_ROLE, 0);
    }

    /**
     * @return The warrant token's cash on cash return aggregated across allIndividualPools
     * @param warrantTokenId The warrant token id's return that this function returns
     */
    function getWarrantTokenReturns(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 dividends;
        uint256 deployedAmount;

        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            dividends += individualPool.getWarrantTokenTotalDividends(
                warrantTokenId
            );
            deployedAmount += individualPool.getWarrantTokenDeployedAmount(
                warrantTokenId
            );
        }

        if (deployedAmount == 0) {
            return 0;
        }

        return (100 * PERCENTAGE_DECIMAL * dividends) / deployedAmount;
    }

    /**
     * @return The warrant token's total dividends aggregated across allIndividualPools
     * @notice Dividends are weighted pro-rata by an investor's contribution
     * @param warrantTokenId The warrant token id's total dividends that this function returns
     */
    function getWarrantTokenTotalDividends(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 warrantTokenTotalDividends;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            warrantTokenTotalDividends += individualPool
                .getWarrantTokenTotalDividends(warrantTokenId);
        }
        return warrantTokenTotalDividends;
    }

    /**
     * @return The warrant token's total unclaimed dividends aggregated across allIndividualPools
     * @notice Dividends are weighted pro-rata by an investor's contribution
     * @param warrantTokenId The warrant token id's total unclaimed dividends that this function returns
     */
    function getWarrantTokenUnclaimedDividends(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 warrantTokenUnclaimedDividends;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            warrantTokenUnclaimedDividends += individualPool
                .getWarrantTokenUnclaimedDividends(warrantTokenId);
        }
        return warrantTokenUnclaimedDividends;
    }

    /**
     * @return The warrant token's cumulative deployed amount aggregated across allIndividualPools
     * @param warrantTokenId The warrant token id's total unclaimed dividends that this function returns
     */
    function getWarrantTokenDeployedAmount(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 warrantTokenTotalDeployed;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            warrantTokenTotalDeployed += individualPool
                .getWarrantTokenDeployedAmount(warrantTokenId);
        }
        return warrantTokenTotalDeployed;
    }

    /**
     * @return The warrant token's cumulative undeployed amount aggregated across allIndividualPools
     * @param warrantTokenId The warrant token id's total undeployed amount that this function returns
     */
    function getWarrantTokenUndeployedAmount(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        uint256 warrantTokenTotalUndeployed;
        for (uint256 i = 0; i < allIndividualPools.length; i++) {
            address poolAddress = allIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            warrantTokenTotalUndeployed += individualPool
                .getWarrantTokenUndeployedAmount(warrantTokenId);
        }
        return warrantTokenTotalUndeployed;
    }

    /// @return Length of currentIndividualPools
    function getCurrentIndividualPoolsLength() external view returns (uint256) {
        return currentIndividualPools.length;
    }

    /// @return Total undeployed amount aggregated across allIndividualPools
    function getTotalUndeployedAmount() public view override returns (uint256) {
        uint256 totalUndeployedAmount;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalUndeployedAmount += individualPool.getTotalUndeployedAmount();
        }
        return totalUndeployedAmount;
    }
}
