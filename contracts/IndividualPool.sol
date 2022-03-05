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

    // --- Recipient State -----------
    // the maximum outstanding balance that recipients can have at one time set by the owner
    uint256 public recipientMaxBalance;

    // the recipient's outstanding balance (recipientMaxBalance - amount withdrawn + amount contributed)
    uint256 public recipientBalance;
    // -------------------------------

    // --- Pool state ----------------
    // Total deployed + undeployed = number of shares allocated to this pool
    // Total amount deployed to this pool
    uint256 public totalDeployed;

    // Total amount undeployed in this pool
    uint256 public totalUndeployed;

    // Total amount of unclaimed dividends in this pool
    uint256 public totalUnclaimedDividends;

    // Total returned in dividends to investors from this pool
    uint256 public cumulativeDividends;

    // investor address => total claimed dividends
    // NOTE: INVESTORS WHO HAVE BOUGHT SHARES ON THE SECONDARY MARKET WILL HAVE ENTRIES IN claimedDividends
    // EVEN IF THEY HADN'T CALLED CLAIMED BEFORE. THIS IS NOT AN ACCURATE MEASURE OF HOW MUCH AN INDIVIDUAL
    // HAS CLAIMED IN DIVIDENDS
    mapping(address => uint256) public claimedDividends;

    // timestamp for first withdrawal in the pool
    uint256 firstWithdrawalTime;

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
    ) external initializer {
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
    function withdraw(uint256 amount)
        external
        onlyRole(RECIPIENT_ROLE)
        whenNotPaused
    {
        require(amount > 0, "You cannot withdraw 0 SLP");

        address sender = _msgSender();
        require(
            amount <= getWithdrawableBalance(),
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

        if (firstWithdrawalTime == 0) {
            firstWithdrawalTime = block.timestamp;
        }

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
    function contribute(uint256 amount)
        external
        onlyRole(RECIPIENT_ROLE)
        whenNotPaused
    {
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

        totalUnclaimedDividends += netContribution;
        cumulativeDividends += netContribution;
        if (amount > recipientBalance) {
            recipientBalance = 0;
        } else {
            recipientBalance -= amount;
        }
        emit Contribute(sender, amount);
        poolToken.safeTransferFrom(sender, address(this), amount);
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
     * @param investor The address of the investor from the aggregate pool
     */
    function investFromAggregatePool(uint256 amount, address investor)
        external
        onlyValidAggregatePool
    {
        require(
            poolToken.balanceOf(investor) >= amount,
            "You don't have enough pool tokens to invest"
        );

        totalUndeployed += amount;
    }

    /**
     * @notice Sends all claimable dividends to the claimer (msg.sender)
     * @notice Must be called by an aggregate pool
     * @dev IMPORTANT: CALLER IS RESPONSIBLE FOR PASSING IN A CORRECT CLAIM AMOUNT VALUE
            Otherwise, this individual pool's dividends could be depleted.
     * @param claimer The investor that made the aggregate pool investment
     * @param claimAmount The amount to claim
     */
    function claimFromAggregatePool(address claimer, uint256 claimAmount)
        external
        onlyValidAggregatePool
    {
        require(claimAmount > 0, "Cannot claim 0");

        require(
            poolToken.balanceOf(address(this)) >= claimAmount,
            "Contract does not have enough to return"
        );
        claimedDividends[claimer] += claimAmount;
        emit Claim(claimer, claimAmount);

        poolToken.safeTransfer(claimer, claimAmount);
    }

    modifier onlyValidAggregatePool() {
        require(
            config.isValidAggregatePool(msg.sender),
            "Contract calling this function is not a valid aggregate pool"
        );
        _;
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
        return cumulativeDividends;
    }

    /**
     * @return The cumulative deployed amount from all recipients, both aggregate pools who have
     * this pool in their allocation and investors who invest directly into this pool.
     */
    function getTotalDeployedAmount() public view override returns (uint256) {
        return totalDeployed;
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

    /**
     * @param investor the investor to get the claimed dividends for
     * @return Total dividends claimed by the investor
     */
    function getInvestorClaimedDividends(address investor)
        external
        view
        override
        returns (uint256)
    {
        return claimedDividends[investor];
    }

    /// @return Timestamp for the first time withdraw() was called in this pool
    function getFirstWithdrawalTime() external view override returns (uint256) {
        return firstWithdrawalTime;
    }

    /// @return Returns the pro-rated amount
    /// @param amount the base amount to pro-rate
    /// @param shares the number of shares held by the individual investor
    /// @param totalShares the total number of shares held by all investors
    function _getProRataForAmount(
        uint256 amount,
        uint256 shares,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return (amount * shares) / totalShares;
    }

    function transferClaimedDividendBalance(
        address from,
        address to,
        uint256 claimedDividendsToTransfer
    ) external onlyValidAggregatePool {
        if (
            claimedDividends[from] > 0 &&
            claimedDividendsToTransfer <= claimedDividends[from]
        ) {
            claimedDividends[to] += claimedDividendsToTransfer;
            claimedDividends[from] -= claimedDividendsToTransfer;
        }
    }
}
