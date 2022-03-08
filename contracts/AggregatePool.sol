// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "./ProtocolConfig.sol";
import "./BasePool.sol";
import "./IndividualPool.sol";

/**
  * @title  OpenGuild's Aggregate Pool contract
  * @notice An AggregatePool is a pool where investors can invest cryptocurrency into multiple IndividualPools and 
            claim dividends from each. Whenever users invest into an aggregate pool, they are minted shares (ERC20 tokens).
  * @dev    1 share = 1 poolToken (ie 1 USDT). Therefore, do not use the aggregate pool's decimals() function in 
            front-end views- use poolToken.decimals() instead.
  */
contract AggregatePool is ERC20Upgradeable, BasePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // --- IAM roles ------------------
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    // --- Pool state ----------------
    // individual pool address => % of investments, map of individual pool address to allocated percentage of investments
    mapping(address => uint256) public individualPoolAllocations;

    // array of indvidual pool addresses that are currently associated with this aggregate pool
    address[] public currentIndividualPools;

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
    ) external initializer {
        require(
            _currentIndividualPools.length > 0,
            "There must be at least one individual pool associated"
        );
        require(
            _currentIndividualPools.length == _currentPercentages.length,
            "The number of pools and percentages are different"
        );

        bool areAllValidIndividualPools = true;
        bool allUseSamePoolToken = true;
        uint256 sum = 0;

        for (uint256 i = 0; i < _currentIndividualPools.length; i++) {
            address poolAddress = _currentIndividualPools[i];
            IndividualPool pool = IndividualPool(poolAddress);

            if (!_config.isValidIndividualPool(poolAddress)) {
                areAllValidIndividualPools = false;
                break;
            }

            if (address(pool.poolToken()) != address(_poolToken)) {
                allUseSamePoolToken = false;
                break;
            }

            uint256 percentage = _currentPercentages[i];
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

        // initialize variables
        poolInvestmentLimit = _poolInvestmentLimit;
        investorInvestmentLimit = _investorInvestmentLimit;
        currentIndividualPools = _currentIndividualPools;

        __BasePool__init(
            _owner,
            _config,
            _poolToken,
            ProtocolConfig.PoolType.AggregatePool
        );

        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            individualPoolAllocations[poolAddress] = _currentPercentages[i];
            poolToken.safeApprove(poolAddress, 2**256 - 1);
        }

        individualPoolAllocations[currentIndividualPools[0]] += sumDifference;

        _setRoleAdmin(INVESTOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, OWNER_ROLE);
        _setupRole(POOL_MANAGER_ROLE, _owner);

        __ERC20_init_unchained("OpenGuild v1 Aggregate Pool", "ogV1AggPool");
    }

    /**
     * @notice Returns the absolute difference between a and b
     * @param a Number to subtract
     * @param b Number to subtract
     * @return the absolute difference between a and b
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
     * @param newPercentages Corresponding allocation percentages to the individual pool addresses
     */
    function setPoolAllocations(uint256[] memory newPercentages)
        external
        onlyRole(POOL_MANAGER_ROLE)
    {
        require(
            newPercentages.length == currentIndividualPools.length,
            "The number of new percentages and current individual pools are different"
        );

        uint256 sum = 0;

        for (uint256 i = 0; i < newPercentages.length; i++) {
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

        for (uint256 i = 0; i < newPercentages.length; i++) {
            address poolAddress = currentIndividualPools[i];
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
    function invest(uint256 amount)
        external
        onlyRole(INVESTOR_ROLE)
        whenNotPaused
    {
        require(amount > 0, "You must invest more than 0");
        address investor = _msgSender();
        require(
            poolToken.balanceOf(investor) >= amount,
            "You don't have enough pool tokens to invest"
        );

        // the total minted amount of shares is guaranteed to be less than the pool
        // investment limit because of this check
        require(
            amount + getTotalDeployedAmount() + getTotalUndeployedAmount() <=
                poolInvestmentLimit,
            "This pool has already reached its max investment"
        );

        require(
            amount + totalInvestedAmountForInvestor[investor] <=
                investorInvestmentLimit,
            "This investor has already invested the max amount for this pool"
        );

        totalInvestedAmountForInvestor[investor] += amount;

        // mint fungible tokens from this contract to the investor
        _mint(investor, amount);

        poolToken.safeTransferFrom(investor, address(this), amount);
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            uint256 poolAmount = _multiplyByAllocationPercentage(
                poolAddress,
                amount
            );
            if (poolAmount > 0) {
                IndividualPool individualPool = IndividualPool(poolAddress);
                individualPool.investFromAggregatePool(poolAmount);
            }
        }
        emit Invest(investor, amount);
    }

    /**
     * @notice Claim all unclaimed dividends from currentIndividualPools
     */
    function claim() public whenNotPaused nonReentrant {
        _claim(msg.sender);
    }

    /** @notice Private claim function that takes in the claimer address as a parameter
        @param  claimer the address of the claimer
     */
    function _claim(address claimer) private {
        uint256 totalShares = totalSupply();

        require(totalShares != 0, "Total shares cannot be 0");

        require(getInvestorUnclaimedDividends(claimer) > 0, "Nothing to claim");

        uint256 claimerShares = balanceOf(claimer);

        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);

            uint256 claimAmount = ((individualPool.cumulativeDividends() *
                claimerShares) / (totalShares)) -
                individualPool.claimedDividends(claimer);

            if (
                claimAmount > 0 &&
                poolToken.balanceOf(poolAddress) >= claimAmount
            ) {
                individualPool.claimFromAggregatePool(claimer, claimAmount);
            }
        }
    }

    /**
     * @notice Amount multiplied by allocation percentage of the individual pool passed in
     * @param individualPool The address of the individual pool's allocation used to calculate pro-rata amount
     * @param amount The amount to be split by pool allocation
     * @return the amount multiplied by the allocation to the individual pool
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

    /**
     * @notice Gets the address of the pool manager
     * @return Address of the pool manager
     */
    function getPoolManager() public view returns (address) {
        return getRoleMember(POOL_MANAGER_ROLE, 0);
    }

    /**
     * @notice Gets the list of current individual pools in this aggregate pool
     * @return a list of addresses of current individual pools
     */
    function getCurrentIndividualPools()
        external
        view
        returns (address[] memory)
    {
        return currentIndividualPools;
    }

    /**
     * @notice Gets the sum of all dividends returned to this aggregate pool
     * @return Sum of all dividends returned to this aggregate pool
     */
    function getCumulativeDividends() external view override returns (uint256) {
        uint256 totalReturned;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalReturned += individualPool.getCumulativeDividends();
        }
        return totalReturned;
    }

    /**
     * @notice Gets the sum of all investments deployed aggregated across currentIndividualPools
     * @return Sum of all investments deployed aggregated across currentIndividualPools
     */
    function getTotalDeployedAmount() public view override returns (uint256) {
        uint256 totalDeployed;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalDeployed += individualPool.getTotalDeployedAmount();
        }
        return totalDeployed;
    }

    /**
     * @notice Gets the total undeployed amount aggregated across currentIndividualPools
     * @return Total undeployed amount aggregated across currentIndividualPools
     */
    function getTotalUndeployedAmount() public view override returns (uint256) {
        uint256 totalUndeployedAmount;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            totalUndeployedAmount += individualPool.getTotalUndeployedAmount();
        }
        return totalUndeployedAmount;
    }

    /**
     * @notice Gets the total undeployed amount aggregated across currentIndividualPools for a single investor
     * @param investor the address of the investor to get the undeployed amount
     * @return Undeployed amount aggregated across currentIndividualPools for a single investor
     */
    function getInvestorUndeployedAmount(address investor)
        external
        view
        returns (uint256)
    {
        uint256 investorUndeployedAmount;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            investorUndeployedAmount += _multiplyByProRata(
                individualPool.getTotalUndeployedAmount(),
                investor
            );
        }
        return investorUndeployedAmount;
    }

    /**
     * @notice Gets the total deployed amount aggregated across currentIndividualPools for a single investor
     * @param investor the address of the investor to get the deployed amount
     * @return Deployed amount aggregated across currentIndividualPools for a single investor
     */
    function getInvestorDeployedAmount(address investor)
        external
        view
        returns (uint256)
    {
        uint256 investorDeployedAmount;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            investorDeployedAmount += _multiplyByProRata(
                individualPool.getTotalDeployedAmount(),
                investor
            );
        }
        return investorDeployedAmount;
    }

    /**
     * @notice Gets the total unclaimed dividends aggregated across currentIndividualPools for a single investor
     * @param investor the address of the investor to get the deployed amount
     * @return Deployed amount aggregated across currentIndividualPools for a single investor
     */
    function getInvestorUnclaimedDividends(address investor)
        public
        view
        returns (uint256)
    {
        uint256 investorUnclaimedDividends;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            investorUnclaimedDividends +=
                _multiplyByProRata(
                    individualPool.getCumulativeDividends(),
                    investor
                ) -
                individualPool.getInvestorClaimedDividends(investor);
        }
        return investorUnclaimedDividends;
    }

    /**
     * @notice Gets the total claimed dividends aggregated across currentIndividualPools for a single investor
     * @param investor the address of the investor to get the deployed amount
     * @return Claimed dividends aggregated across currentIndividualPools for a single investor
     */
    function getInvestorClaimedDividends(address investor)
        external
        view
        override
        returns (uint256)
    {
        uint256 investorClaimedDividends;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            investorClaimedDividends += individualPool
                .getInvestorClaimedDividends(investor);
        }
        return investorClaimedDividends;
    }

    /**
     * @notice Gets the earliest withdrawal timestamp for the individual pools in the aggregate pool
     * @return The earliest withdrawal timestamp for the individual pools in the aggregate pool
     */
    function getFirstWithdrawalTime() external view override returns (uint256) {
        uint256 firstWithdrawalTime = 2**256 - 1;
        for (uint256 i = 0; i < currentIndividualPools.length; i++) {
            address poolAddress = currentIndividualPools[i];
            IndividualPool individualPool = IndividualPool(poolAddress);
            if (individualPool.getFirstWithdrawalTime() < firstWithdrawalTime) {
                firstWithdrawalTime = individualPool.getFirstWithdrawalTime();
            }
        }
        return firstWithdrawalTime;
    }

    /**
     * @notice Given an input amount, returns the amount muliplied by an individual
     *         investor's proportion of ownership in the pool (pro-rated ownership)
     * @param amount the amount to multiply by the investor's pro-rated token amount
     * @param investor the address of the investor to get the pro-rated amount for
     * @return the amount multiplied by the investor's ownership
     */
    function _multiplyByProRata(uint256 amount, address investor)
        internal
        view
        returns (uint256)
    {
        if (totalSupply() == 0) {
            return 0;
        }
        return (amount * balanceOf(investor)) / totalSupply();
    }

    /**
     * @notice Transfer claimed dividends to new token owner to prevent them from claiming more than what they're owed
     * @param from the current owner of the tokens
     * @param to the new owner of the tokens
     * @param amount the number of tokens to transfer
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // No need to transfer balances if we're minting warrant tokens
        if (from != address(0)) {
            if (getInvestorUnclaimedDividends(from) > 0) {
                _claim(from);
            }
            for (uint256 i = 0; i < currentIndividualPools.length; i++) {
                address poolAddress = currentIndividualPools[i];
                IndividualPool individualPool = IndividualPool(poolAddress);

                if (individualPool.claimedDividends(from) > 0) {
                    uint256 claimedDividendsToTransfer = (individualPool
                        .claimedDividends(from) * amount) / balanceOf(from);
                    individualPool.transferClaimedDividendBalance(
                        from,
                        to,
                        claimedDividendsToTransfer
                    );
                }
            }
        }
    }
}
