// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./external/BaseUpgradeablePausable.sol";
import "./ProtocolConfig.sol";
import "./BasePool.sol";
import "./AggregatePool.sol";

/**
 * @title OpenGuild's Individual Pool contract
 * @notice An Individual is a pool where anyone can withdraw cryptocurrency from the pool and pay it back over time.
 */

contract IndividualPool is BasePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    // --- IAM Roles ------------------
    bytes32 public constant RECIPIENT_ROLE = keccak256("RECIPIENT_ROLE");

    // --- Investor State -------------
    // warrant token id => warrantTokenTotalDividends, dividends that a warrant token owner has ever accumulated
    mapping(uint256 => uint256) public warrantTokenTotalDividends;

    // warrant token id => warrantTokenUnclaimedDividends, dividends that a warrant token owner has not claimed yet
    mapping(uint256 => uint256) public warrantTokenUnclaimedDividends;

    // warrant token id => warrantTokenUndeployedAmount, amount of capital associated with warrant token id that is undeployed
    mapping(uint256 => uint256) public warrantTokenUndeployedAmount;

    // Array of warrant token ids that have undeployed capital
    uint256[] warrantTokenIdUndeployed;
    // Index of the warrant token ID at the head of the list
    uint256 warrantTokenIdUndeployedIndex;

    // warrant token id => warrantTokenDeployedAmount, how much of an investor's capital that has been deployed
    mapping(uint256 => uint256) public warrantTokenDeployedAmount;

    // Array of warrant token ids that have deployed capital
    uint256[] warrantTokenIdDeployed;
    // -------------------------------

    // --- Recipient State -----------
    // the maximum outstanding balance that recipients can have at one time set by the owner
    uint256 public recipientMaxBalance;

    // the recipient's outstanding balance (recipientMaxBalance - amount withdrawn + amount contributed)
    uint256 public recipientBalance;
    // -------------------------------

    // --- Pool state ----------------
    // Total amount deployed to this pool
    uint256 public totalDeployed;

    // Total amount undeployed in this pool
    uint256 public totalUndeployed;

    // Total returned in dividends to investors from this pool
    uint256 public totalDividends;

    /**
     * @notice Run only once, on initialization
     * @param _owner The address that is assigned the "OWNER_ROLE" of this contract
     * @param _config The address of the OpenGuild ProtocolConfig contract
     * @param _poolToken The ERC20 token denominating investments, withdrawals and contributions
     * @param _recipient The recipient of this individual pool
     */
    function initialize(
        address _owner,
        ProtocolConfig _config,
        IERC20Upgradeable _poolToken,
        address _recipient
    ) public initializer {
        require(_recipient != address(0), "Recipient cannot be the 0 address");

        // initialize variables

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
    /**
     * @notice Withdraws capital and updates undeployed and deployed balances
     * @notice Only callable by the recipient
     * @param amount Amount to be withdrawn
     */
    function withdraw(uint256 amount) external onlyRole(RECIPIENT_ROLE) {
        require(amount > 0, "You cannot withdraw 0 SLP");

        address sender = _msgSender();
        uint256 withdrawableBalance = getWithdrawableBalance();
        require(
            amount <= withdrawableBalance,
            "You cannot withdraw more than your maximum balance"
        );

        require(
            amount <= totalUndeployed,
            "Not enough undeployed capital to withdraw"
        );

        require(
            poolToken.balanceOf(address(this)) >= amount,
            "Contract doesn't have enough pool tokens"
        );

        uint256 remainingAmount = amount;
        uint256 index = warrantTokenIdUndeployedIndex;
        while (index < warrantTokenIdUndeployed.length && remainingAmount > 0) {
            if (warrantTokenIdUndeployed[index] == 0) {
                index += 1;
                continue;
            }
            uint256 warrantTokenId = warrantTokenIdUndeployed[index];
            uint256 undeployedAmount = warrantTokenUndeployedAmount[
                warrantTokenId
            ];
            if (warrantTokenDeployedAmount[warrantTokenId] == 0) {
                warrantTokenIdDeployed.push(warrantTokenId);
            }
            if (remainingAmount >= undeployedAmount) {
                index += 1;
                remainingAmount -= undeployedAmount;
                warrantTokenUndeployedAmount[
                    warrantTokenId
                ] -= undeployedAmount;
                warrantTokenDeployedAmount[warrantTokenId] += undeployedAmount;
            } else {
                warrantTokenUndeployedAmount[warrantTokenId] -= remainingAmount;
                warrantTokenDeployedAmount[warrantTokenId] += remainingAmount;
                remainingAmount = 0;
            }
        }

        warrantTokenIdUndeployedIndex = index;
        totalUndeployed -= amount;
        totalDeployed += amount;
        recipientBalance += amount;
        emit Withdraw(sender, amount);
        poolToken.safeTransfer(sender, amount);
    }

    /**
     * @notice Contributes capital and disburses the dividends to warrant tokens accordingly
     * @notice Only callable by the recipient
     * @param amount Amount to be contributed
     */
    function contribute(uint256 amount) external onlyRole(RECIPIENT_ROLE) {
        require(amount > 0, "You cannot contribute 0 SLP");

        require(totalDeployed > 0, "There is no deployed capital");

        require(
            poolToken.balanceOf(_msgSender()) >= amount,
            "You don't have enough pool tokens to contribute the amount passed in"
        );
        address sender = _msgSender();

        (uint256 protocolFee, uint256 netContribution) = applyFee(
            amount,
            config.getProtocolTakeRate()
        );
        poolToken.safeTransferFrom(sender, address(this), amount);

        for (uint256 i = 0; i < warrantTokenIdDeployed.length; i++) {
            uint256 warrantTokenId = warrantTokenIdDeployed[i];
            uint256 dividend = _getProRataForWarrantTokenId(
                netContribution,
                warrantTokenId
            );
            warrantTokenUnclaimedDividends[warrantTokenId] += dividend;
            warrantTokenTotalDividends[warrantTokenId] += dividend;
        }

        totalDividends += netContribution;
        if (amount > recipientBalance) {
            recipientBalance = 0;
        } else {
            recipientBalance -= amount;
        }
        emit Contribute(sender, amount);
        poolToken.safeTransfer(config.getTreasuryAddress(), protocolFee);
    }

    /**
        Investor functions
     */

    /**
     * @notice Invest function called by an aggregate pool
     * @notice Only callable by an aggregate pool
     * @dev The warrant token is issued by the issuing aggregate pool, not this individual pool
     * @param amount The amount to be invested
     * @param warrantTokenId The aggregate pool warrant token that the investment is tied to
     * @param investor The address of the investor from the aggregate pool
     */
    function investFromAggregatePool(
        uint256 amount,
        uint256 warrantTokenId,
        address investor
    ) external onlyValidAggregatePool {
        require(
            poolToken.balanceOf(investor) >= amount,
            "You don't have enough pool tokens to invest"
        );

        totalInvestedAmountForInvestor[investor] += amount;

        warrantTokenIdUndeployed.push(warrantTokenId);
        warrantTokenUndeployedAmount[warrantTokenId] += amount;
        totalUndeployed += amount;
    }

    /**
     * @notice Sends all claimable dividends to the claimer (msg.sender)
     * @notice Must be called by an aggregate pool
     * @param claimer The investor that made the aggregate pool investment
     */
    function claimFromAggregatePool(address claimer)
        external
        onlyValidAggregatePool
    {
        address issuingPool = _msgSender();

        uint256[] memory warrantTokenIds = warrantToken
            .getWarrantTokensByOwnerAndPoolAddress(
                claimer,
                issuingPool,
                ProtocolConfig.PoolType.AggregatePool
            );
        require(
            warrantTokenIds.length > 0,
            "Couldn't find any tokens for the given claimer and issuing pool"
        );

        uint256 claimAmount;
        for (uint256 i = 0; i < warrantTokenIds.length; i++) {
            uint256 warrantTokenId = warrantTokenIds[i];
            claimAmount += warrantTokenUnclaimedDividends[warrantTokenId];
        }
        require(
            poolToken.balanceOf(address(this)) >= claimAmount,
            "Contract does not have enough to return"
        );
        for (uint256 i = 0; i < warrantTokenIds.length; i++) {
            uint256 warrantTokenId = warrantTokenIds[i];
            delete warrantTokenUnclaimedDividends[warrantTokenId];
        }
        if (claimAmount > 0) {
            emit Claim(claimer, claimAmount);
            poolToken.safeTransfer(claimer, claimAmount);
        }
    }

    modifier onlyValidAggregatePool() {
        require(
            config.isValidAggregatePool(msg.sender),
            "Contract calling this function is not a valid aggregate pool"
        );
        _;
    }

    /**
     * @notice Removes undeployed capital from warrant tokens
     * @notice Only callable by the owner
     * @dev Called in the case the recipient of this individual pool goes rogue
     * @param warrantTokenIds The warrant tokens to remove undeployed capital from
     */
    function removeUndeployedCapital(uint256[] memory warrantTokenIds)
        external
        onlyRole(OWNER_ROLE)
    {
        for (uint256 i = 0; i < warrantTokenIds.length; i++) {
            uint256 warrantTokenId = warrantTokenIds[i];
            address warrantTokenOwner = warrantToken.ownerOf(warrantTokenId);
            uint256 amount = warrantTokenUndeployedAmount[warrantTokenId];
            require(
                amount > 0,
                "There is no capital to undeploy from this warrant token"
            );

            // uint256 warrantTokenPosition = undeployedQueue
            //     .warrantTokenIdToPosition(warrantTokenId);
            // require(
            //     warrantTokenPosition >= undeployedQueue.first() &&
            //         warrantTokenPosition <= undeployedQueue.last(),
            //     "This warrant token is no longer in the undeployed queue"
            // );
            warrantTokenUndeployedAmount[warrantTokenId] = 0;
            totalUndeployed -= amount;
            // uint256 warrantTokenPosition = undeployedQueue.warrantTokenIdToPosition(
            //     warrantTokenId
            // );
            // Investment memory removedNode = undeployedQueue.remove(
            //     warrantTokenPosition
            // );

            emit RemoveUndeployedCapital(warrantTokenOwner, warrantTokenId);
            poolToken.safeTransfer(warrantTokenOwner, amount);
        }
    }

    /// @return The current withdrawable balance
    function getWithdrawableBalance() public view returns (uint256) {
        require(recipientMaxBalance > 0, "Recipient max balance not set");
        if (recipientBalance > recipientMaxBalance) {
            return 0;
        }

        return recipientMaxBalance - recipientBalance;
    }

    /**
     * @notice Sets the new max balance
     * @param amount The new max balance
     */
    function setMaxBalance(uint256 amount) external onlyRole(OWNER_ROLE) {
        recipientMaxBalance = amount;
    }

    /**
     * @notice Replace the current recipient with a new recipient
     * @notice Only callable by the owner
     * @dev There can only be one recipient at a time
     * @param newRecipient The address of the new recipient
     */
    function setRecipient(address newRecipient) external onlyRole(OWNER_ROLE) {
        address recipient = getRecipient();

        revokeRole(RECIPIENT_ROLE, recipient);
        grantRole(RECIPIENT_ROLE, newRecipient);
        require(
            getRoleMemberCount(RECIPIENT_ROLE) == 1,
            "Only one recipient could be set at a time!"
        );
    }

    /// @return Current recipient address
    function getRecipient() public view returns (address) {
        return getRoleMember(RECIPIENT_ROLE, 0);
    }

    /**
     * @return The sum of all dividends returned by this individual pool to all recipients,
     * both aggregate pools who have this pool in their allocation and investors who invest
     * directly into this pool
     */
    function getCumulativeDividends() public view override returns (uint256) {
        return totalDividends;
    }

    /**
     * @return The cumulative deployed amount from all recipients, both aggregate pools who have
     * this pool in their allocation and investors who invest directly into this pool.
     */
    function getCumulativeDeployedAmount()
        public
        view
        override
        returns (uint256)
    {
        return totalDeployed;
    }

    /**
     * @return Percent returns for a warrant token
     * @param warrantTokenId The warrant token id' returns that this function will return
     */
    function getWarrantTokenReturns(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        if (warrantTokenDeployedAmount[warrantTokenId] == 0) {
            return 0;
        }
        return
            (100 *
                PERCENTAGE_DECIMAL *
                warrantTokenTotalDividends[warrantTokenId]) /
            warrantTokenDeployedAmount[warrantTokenId];
    }

    /**
     * @return The warrant token's total dividends in this individual pool
     * @notice Dividends are weighted pro-rata by an investor's contribution
     * @param warrantTokenId The warrant token id's total dividends that this function returns
     */
    function getWarrantTokenTotalDividends(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        return warrantTokenTotalDividends[warrantTokenId];
    }

    /**
     * @return The warrant token's total unclaimed dividends in this individual pool
     * @notice Dividends are weighted pro-rata by an investor's contribution
     * @param warrantTokenId The warrant token id's total unclaimed dividends that this function returns
     */
    function getWarrantTokenUnclaimedDividends(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        return warrantTokenUnclaimedDividends[warrantTokenId];
    }

    /**
     * @return The warrant token's cumulative deployed amount in this individualPool
     * @param warrantTokenId The warrant token id's total unclaimed dividends that this function returns
     */
    function getWarrantTokenDeployedAmount(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        return warrantTokenDeployedAmount[warrantTokenId];
    }

    /**
     * @return The warrant token's cumulative undeployed amount in this individual pool
     * @param warrantTokenId The warrant token id's total undeployed amount that this function returns
     */
    function getWarrantTokenUndeployedAmount(uint256 warrantTokenId)
        external
        view
        override
        returns (uint256)
    {
        return warrantTokenUndeployedAmount[warrantTokenId];
    }

    /**
     * @return The undeployed warrant token at the given index
     * @param warrantTokenIdIndex The warrant token id's total undeployed amount that this function returns
     */
    function getWarrantTokenIdUndeployed(uint256 warrantTokenIdIndex)
        external
        view
        returns (uint256)
    {
        return warrantTokenIdUndeployed[warrantTokenIdIndex];
    }

    /**
     * @return The warrantTokenIdUndeployedIndex
     */
    function getWarrantTokenIdUndeployedIndex()
        external
        view
        returns (uint256)
    {
        return warrantTokenIdUndeployedIndex;
    }

    /// @return Total undeployed amount in this individual pool
    function getTotalUndeployedAmount()
        external
        view
        override
        returns (uint256)
    {
        return totalUndeployed;
    }

    /// @return Amount proportional to the deployed amount for a warrant token and total deployed in this pool
    function _getProRataForWarrantTokenId(
        uint256 amount,
        uint256 warrantTokenId
    ) internal view returns (uint256) {
        return
            (amount * warrantTokenDeployedAmount[warrantTokenId]) /
            totalDeployed;
    }

    function getFirstUndeployedWarrantToken() public view returns (uint256) {
        if (warrantTokenIdUndeployedIndex >= warrantTokenIdUndeployed.length) {
            return 0;
        }
        return warrantTokenIdUndeployed[warrantTokenIdUndeployedIndex];
    }

    function getLastUndeployedWarrantToken() public view returns (uint256) {
        if (warrantTokenIdUndeployed.length == 0) {
            return 0;
        }
        return warrantTokenIdUndeployed[warrantTokenIdUndeployed.length - 1];
    }
}
