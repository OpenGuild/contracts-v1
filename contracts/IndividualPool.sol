// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./external/BaseUpgradeablePausable.sol";
import "./InvestmentQueue.sol";
import "./ProtocolConfig.sol";
import "./BasePool.sol";
import "./AggregatePool.sol";

/**
    An OpenGuild Income Share Pool (OGISP) is a pool where anyone can withdraw cryptocurrency from 
    the pool and pay it back over time.

    An OGISP is initialized with:
      - a staking token address: the token denominating investments, withdrawals, and contributions
      - a reward token address: the token the investor receives as a reward
      - a maximum investment amount: the maximum amount that an investor can contribute at a time

    Investor capital is deployed FIFO. To prevent one investor from taking up most of the proceeds, we
    implement a max investment.
 */

contract IndividualPool is BasePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    string public constant name = "IndividualPool";

    // --- Investor State -------------
    // warrant token id => tokenTotalDividends, dividends that a token owner has ever accumulated
    mapping(uint256 => uint256) public tokenTotalDividends;

    // warrant token id => tokenUnclaimedDividends, dividends that a token owner has not claimed yet
    mapping(uint256 => uint256) public tokenUnclaimedDividends;

    // warrant token id => investorUndeployedAmount, amount of capital associated with warrant token id that is undeployed
    mapping(uint256 => uint256) public undeployedAmountForWarrantToken;

    // token id => investorDeployedAmount, how much of investor's capital that has been deployed
    mapping(uint256 => uint256) public tokenDeployedAmount;

    // Array of warrant token ids that have deployed capital
    uint256[] tokenIdDeployed;

    // pool address => poolDividends; how much in dividends this pool has allocated to other pools
    // this individual pool would put its own address as a key as well
    mapping(address => uint256) public poolDividends;

    // pool address => poolDividends; how much in dividends this pool has allocated to other pools
    // this individual pool would put its own address as a key as well
    mapping(address => uint256) public poolDeployedAmount;

    // Array of pools that have deployed capital
    address[] deployedPools;
    // -------------------------------

    // --- Recipient State -----------
    // the maximum amount that recipients could take out at one time
    // this is a mutable amount that fluctuates based on the pool manager's decision
    // users will not be able to take out another investment until their previous balance's principal
    // has been paid out.
    uint256 public recipientMaxBalance;

    // the difference between balance and contributions
    // for recipients at any given moment
    uint256 public recipientBalance;
    // -------------------------------

    // --- Pool state ----------------
    // How much capital was deposited by investors but not withdrawn
    InvestmentQueue private undeployedQueue;

    // Maximum investment that an investor could make at a given time
    uint256 public maxInvestment;

    // Total amount deployed to this pool
    // We're relying on this instead of `getCumulativeUndeployedAmount` to save on gas fees
    uint256 public totalDeployed;

    // --- IAM Roles ------------------
    bytes32 public constant RECIPIENT_ROLE = keccak256("RECIPIENT_ROLE");

    // -------------------------------

    // https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        address _owner,
        ProtocolConfig _config,
        IERC20Upgradeable _poolToken,
        uint256 _maxInvestment,
        InvestmentQueue _undeployedQueue,
        address _recipient
    ) public initializer {
        require(_recipient != address(0), "Recipient cannot be the 0 address");

        // initial variables
        maxInvestment = _maxInvestment;
        undeployedQueue = _undeployedQueue;

        __BasePool__init(
            _owner,
            _config,
            _poolToken,
            ProtocolConfig.PoolType.IndividualPool
        );
        _setRoleAdmin(RECIPIENT_ROLE, OWNER_ROLE);
        _setupRole(RECIPIENT_ROLE, _recipient);
    }

    /**
        Recipient functions
     */
    function withdraw(uint256 amount) external onlyRole(RECIPIENT_ROLE) {
        require(amount > 0, "You cannot withdraw 0 SLP");

        address sender = _msgSender();
        uint256 withdrawableBalance = getMaxBalance();
        require(
            amount <= withdrawableBalance,
            "You cannot withdraw more than your maximum balance"
        );

        require(
            amount <= undeployedQueue.totalAmount(),
            "Not enough undeployed capital to withdraw"
        );

        require(
            poolToken.balanceOf(address(this)) >= amount,
            "Contract doesn't have enough in balance"
        );

        uint256 remainingAmount = amount;
        while (!undeployedQueue.isEmpty() && remainingAmount > 0) {
            Investment memory head = undeployedQueue.peek();
            address issuingPool = warrantToken.getPool(head.tokenId);

            if (tokenDeployedAmount[head.tokenId] == 0) {
                tokenIdDeployed.push(head.tokenId);
            }
            if (poolDeployedAmount[issuingPool] == 0) {
                deployedPools.push(issuingPool);
            }
            if (remainingAmount >= head.amount) {
                undeployedQueue.dequeue();
                remainingAmount -= head.amount;
                undeployedAmountForWarrantToken[head.tokenId] -= head.amount;
                tokenDeployedAmount[head.tokenId] += head.amount;
                poolDeployedAmount[issuingPool] += head.amount;
            } else {
                undeployedQueue.decrementAmountAtHead(remainingAmount);
                undeployedAmountForWarrantToken[
                    head.tokenId
                ] -= remainingAmount;
                tokenDeployedAmount[head.tokenId] += remainingAmount;
                poolDeployedAmount[issuingPool] += remainingAmount;
                remainingAmount = 0;
            }
        }

        totalDeployed += amount;
        recipientBalance += amount;
        emit WithdrawInvestment(sender, amount);
        poolToken.safeTransfer(sender, amount);
    }

    function contribute(uint256 amount) external onlyRole(RECIPIENT_ROLE) {
        require(amount > 0, "You cannot contribute 0 SLP");

        require(totalDeployed > 0, "There is no deployed capital");

        require(
            poolToken.balanceOf(_msgSender()) >= amount,
            "You don't have enough tokens to contribute the amount passed in"
        );
        address sender = _msgSender();

        (uint256 protocolFee, uint256 netContribution) = applyFee(
            amount,
            config.getProtocolTakeRate()
        );
        poolToken.safeTransferFrom(sender, address(this), amount);

        for (uint256 i = 0; i < tokenIdDeployed.length; i++) {
            uint256 tokenId = tokenIdDeployed[i];
            address issuingPool = warrantToken.getPool(tokenId);
            uint256 dividend = _getProRataForTokenId(netContribution, tokenId);
            tokenUnclaimedDividends[tokenId] += dividend;
            tokenTotalDividends[tokenId] += dividend;
            poolDividends[issuingPool] += dividend;
            if (
                warrantToken.getPoolType(tokenId) ==
                ProtocolConfig.PoolType.AggregatePool
            ) {
                AggregatePool aggregatePool = AggregatePool(issuingPool);
                (uint256 poolManagerFee, ) = applyFee(
                    _getProRataForTokenId(amount, tokenId),
                    config.getPoolManagerTakeRate()
                );
                tokenUnclaimedDividends[tokenId] -= poolManagerFee;
                tokenTotalDividends[tokenId] -= poolManagerFee;
                poolDividends[issuingPool] -= poolManagerFee;
                poolToken.safeTransfer(
                    aggregatePool.getPoolManager(),
                    poolManagerFee
                );
            }
        }

        if (amount > recipientBalance) {
            recipientBalance = 0;
        } else {
            recipientBalance -= amount;
        }
        emit DepositContribution(sender, amount);
        poolToken.safeTransfer(config.getTreasuryAddress(), protocolFee);
    }

    /**
        Investor functions
     */
    // Called when an investor invests into a pool
    function invest(uint256 amount) external onlyRole(INVESTOR_ROLE) {
        require(amount > 0, "You must invest more than 0");

        address investor = _msgSender();
        uint256 tokenId = warrantToken.mint(investor, address(this), poolType);
        emit Invest(tokenId, investor, amount);
        _invest(amount, tokenId, investor, address(this));
    }

    function investFromAggregatePool(
        uint256 amount,
        uint256 tokenId,
        address investor,
        address issuingPool
    ) external onlyValidAggregatePoolOrAdmin {
        _invest(amount, tokenId, investor, issuingPool);
    }

    function _invest(
        uint256 amount,
        uint256 tokenId,
        address investor,
        address issuingPool
    ) private {
        require(
            poolToken.balanceOf(investor) >= amount,
            "You don't have enough tokens to invest"
        );
        require(
            amount <= maxInvestment,
            "Amount invested exceeds the maximum investment"
        );
        undeployedAmountForWarrantToken[tokenId] += amount;
        undeployedQueue.enqueue(tokenId, amount, block.timestamp);
        if (issuingPool == address(this)) {
            poolToken.safeTransferFrom(investor, address(this), amount);
        }
    }

    modifier onlyValidAggregatePoolOrAdmin() {
        require(
            isAdmin() || config.isValidAggregatePool(msg.sender),
            "Contract calling this function is not a valid aggregate pool"
        );
        _;
    }

    // Sends all claimable dividends to the claimer (msg.sender)
    // Must be called by direct investors, or non-aggregate pool investors
    function claim() external onlyRole(INVESTOR_ROLE) {
        address claimer = _msgSender();
        address issuingPool = address(this);

        _claim(claimer, issuingPool, ProtocolConfig.PoolType.IndividualPool);
    }

    // Sends all claimable dividends to the claimer (msg.sender)
    // Must be called by aggregate pools, which explicitly pass in the claimer
    function claimFromAggregatePool(address claimer)
        external
        onlyValidAggregatePoolOrAdmin
    {
        address issuingPool = _msgSender();

        _claim(claimer, issuingPool, ProtocolConfig.PoolType.AggregatePool);
    }

    // Claim all dividends available to the given warrant token IDs
    function _claim(
        address claimer,
        address issuingPool,
        ProtocolConfig.PoolType poolType
    ) private {
        uint256[] memory tokenIds = warrantToken.getTokensByOwnerAndPoolAddress(
            claimer,
            issuingPool,
            poolType
        );
        require(
            tokenIds.length > 0,
            "Couldn't find any tokens for the given claimer and issuing pool"
        );

        uint256 claimAmount;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            claimAmount += tokenTotalDividends[tokenId];
        }
        require(
            poolToken.balanceOf(address(this)) >= claimAmount,
            "Contract does not have enough to return"
        );
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            delete tokenUnclaimedDividends[tokenId];
        }
        if (claimAmount > 0) {
            emit Claim(claimer, claimAmount);
            poolToken.safeTransfer(claimer, claimAmount);
        }
    }

    function removeUndeployedCapital(uint256[] memory tokenIds)
        external
        onlyRole(INVESTOR_ROLE)
    {
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

            uint256 tokenPosition = undeployedQueue.tokenIdToPosition(tokenId);
            require(
                tokenPosition >= undeployedQueue.first() &&
                    tokenPosition <= undeployedQueue.last(),
                "This token is no longer in the undeployed queue"
            );

            address remover = _msgSender();
            address issuingPool = warrantToken.getPool(tokenId);
            require(
                issuingPool == address(this),
                "This token was not issued by this pool"
            );
            if (tokenDeployedAmount[tokenId] == 0) {
                warrantToken.burn(tokenId);
            }
            _removeUndeployedCapital(remover, tokenId);
        }
    }

    function removeUndeployedFromAggregatePool(address remover, uint256 tokenId)
        external
        onlyValidAggregatePoolOrAdmin
    {
        // this returns the aggregate pool address
        address issuingPool = warrantToken.getPool(tokenId);
        require(
            issuingPool == _msgSender(),
            "This token was not issued by this pool"
        );

        _removeUndeployedCapital(remover, tokenId);
    }

    function _removeUndeployedCapital(address remover, uint256 tokenId)
        private
    {
        undeployedAmountForWarrantToken[tokenId] = 0;
        uint256 nftPosition = undeployedQueue.tokenIdToPosition(tokenId);
        Investment memory removedNode = undeployedQueue.remove(nftPosition);
        poolToken.safeTransfer(remover, removedNode.amount);
    }

    function getMaxBalance() public view returns (uint256) {
        require(recipientMaxBalance > 0, "Recipient max balance not set");
        require(
            recipientBalance < recipientMaxBalance,
            "Recipient has withdrawn max amount already"
        );

        return recipientMaxBalance - recipientBalance;
    }

    function setMaxBalance(uint256 amount) external onlyRole(OWNER_ROLE) {
        recipientMaxBalance = amount;
    }

    function setRecipient(address newRecipientAddress)
        external
        onlyRole(OWNER_ROLE)
    {
        address recipientAddress = getRecipient();

        revokeRole(RECIPIENT_ROLE, recipientAddress);
        grantRole(RECIPIENT_ROLE, newRecipientAddress);
        require(
            getRoleMemberCount(RECIPIENT_ROLE) == 1,
            "Only one recipient could be set at a time!"
        );
    }

    function getRecipient() public view returns (address) {
        return getRoleMember(RECIPIENT_ROLE, 0);
    }

    // Returns the sum of all dividends returned by this individual pool to all recipients,
    // both aggregate pools who have this pool in their allocation and investors who invest
    // directly into this pool
    function getCumulativeDividends() public view override returns (uint256) {
        uint256 totalDividends = 0;

        for (uint256 i = 0; i < deployedPools.length; i++) {
            totalDividends += poolDividends[deployedPools[i]];
        }
        return totalDividends;
    }

    // Returns cumulative deployed amount from all recipients, both aggregate pools who have
    // this pool in their allocation and investors who invest directly into this pool
    function getCumulativeDeployedAmount()
        public
        view
        override
        returns (uint256)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < deployedPools.length; i++) {
            total += poolDeployedAmount[deployedPools[i]];
        }

        assert(total == totalDeployed);
        return total;
    }

    // Returns undeployed balances for a pool address. Passing in the current pool's address
    // should return only the dividends returned to investors who directly invested into this
    // individual pool
    function getCumulativeDividendsForPool(address pool)
        public
        view
        returns (uint256)
    {
        return poolDividends[pool];
    }

    // Returns deployed amount for a pool address. Passing in the current pool's address
    // should return only the deployed amount returned to investors who directly invested into this
    // individual pool
    function getCumulativeDeployedAmountForPool(address pool)
        public
        view
        returns (uint256)
    {
        return poolDeployedAmount[pool];
    }

    // Returns the returns for a token
    function getReturnsForToken(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        if (tokenDeployedAmount[tokenId] == 0) {
            return 0;
        }
        return
            (100 * PERCENTAGE_DECIMAL * tokenTotalDividends[tokenId]) /
            tokenDeployedAmount[tokenId];
    }

    function getTokenTotalDividends(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        return tokenTotalDividends[tokenId];
    }

    function getTokenUnclaimedDividends(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        return tokenUnclaimedDividends[tokenId];
    }

    function getTokenDeployedAmount(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        return tokenDeployedAmount[tokenId];
    }

    function getUndeployedAmountForWarrantToken(uint256 tokenId)
        external
        view
        override
        returns (uint256)
    {
        return undeployedAmountForWarrantToken[tokenId];
    }

    function getTotalUndeployedAmount()
        external
        view
        override
        returns (uint256)
    {
        return undeployedQueue.totalAmount();
    }

    // Calculates an amount proportional to the deployed amount for a token and total deployed for a pool
    function _getProRataForTokenId(uint256 amount, uint256 tokenId)
        internal
        view
        returns (uint256)
    {
        return (amount * tokenDeployedAmount[tokenId]) / totalDeployed;
    }
}
