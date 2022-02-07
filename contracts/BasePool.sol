// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./external/BaseUpgradeablePausable.sol";
import "./WarrantToken.sol";
import "./ProtocolConfig.sol";

/**
 * @title OpenGuild's Base Pool contract
 * @notice This is the BasePool contract that the IndividualPool and AggregatePool contracts inherit from
 */

abstract contract BasePool is BaseUpgradeablePausable {
    // Precision of allocation percentages (1 percent == PERCENTAGE_DECIMAL)
    uint256 public constant PERCENTAGE_DECIMAL = 10**16;

    // ERC20 token that the pool is denominated in
    IERC20Upgradeable public poolToken;

    // ERC721 token that grants the owner the right to withdraw dividends from the pool
    WarrantToken public warrantToken;

    // investor address => totalInvestedAmountForInvestor, how much an investor has invested into the pool so far
    mapping(address => uint256) public totalInvestedAmountForInvestor;

    ProtocolConfig internal config;

    ProtocolConfig.PoolType public poolType;

    event Invest(uint256 warrantTokenId, address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event Claim(address indexed from, uint256 amount);
    event Contribute(address indexed from, uint256 amount);
    event RemoveUndeployedCapital(
        address indexed remover,
        uint256 warrantTokenId
    );

    /**
     * @notice Run only once, on initialization
     * @param _owner The address of who should have the "OWNER_ROLE" of this contract
     * @param _config The address of the OpenGuild ProtocolConfig contract
     * @param _poolToken The ERC20 token denominating investments, withdrawals and contributions
     * @param _poolType The pool type of the BasePool
     */
    function __BasePool__init(
        address _owner,
        ProtocolConfig _config,
        IERC20Upgradeable _poolToken,
        ProtocolConfig.PoolType _poolType
    ) public initializer {
        poolToken = _poolToken;
        config = _config;

        poolType = _poolType;

        address existingWarrantTokenAddress = config.getWarrantTokenAddress();
        require(
            existingWarrantTokenAddress != address(0),
            "Warrant token address hasn't been set on ProtocolConfig"
        );
        warrantToken = WarrantToken(existingWarrantTokenAddress);

        __BaseUpgradeablePausable__init(_owner);
    }

    /**
     * @return Tuple of OpenGuild's take + remainder
     * @param amount Amount to subtract the fee from
     * @param takeRate Rate to calculate the fee
     */
    function applyFee(uint256 amount, uint256 takeRate)
        public
        view
        returns (uint256, uint256)
    {
        uint256 fee = (amount * takeRate) / config.getTakeRatePrecision();
        uint256 remainder = amount - fee;
        assert(fee + remainder == amount);

        return (fee, remainder);
    }

    /// @return The sum of all dividends returned to this pool
    function getCumulativeDividends() public view virtual returns (uint256) {}

    /**
     * @return The warrant token's returns
     * @param warrantTokenId The warrant token id's returns this function returns
     */
    function getWarrantTokenReturns(uint256 warrantTokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    /**
     * @return The warrant token's total dividends
     * @param warrantTokenId The warrant token id's total dividends that this function returns
     */
    function getWarrantTokenTotalDividends(uint256 warrantTokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    /**
     * @return The warrant token's total unclaimed dividends
     * @param warrantTokenId The warrant token id's total unclaimed dividends that this function returns
     */
    function getWarrantTokenUnclaimedDividends(uint256 warrantTokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    /**
     * @return The warrant token's total deployed amount
     * @param warrantTokenId The warrant token id's total deployed amount that this function returns
     */
    function getWarrantTokenDeployedAmount(uint256 warrantTokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    /**
     * @return The warrant token's total undeployed amount
     * @param warrantTokenId The warrant token id's total undeployed amount that this function returns
     */
    function getWarrantTokenUndeployedAmount(uint256 warrantTokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    /// @return Total undeployed amount in the pool
    function getTotalUndeployedAmount()
        external
        view
        virtual
        returns (uint256)
    {}

    /// @return Total deployed amount in the pool
    function getCumulativeDeployedAmount()
        public
        view
        virtual
        returns (uint256)
    {}

    /// @return Cumulative cash on cash returns of the current pool, to the same digits of precision as the poolToken
    function getCumulativeReturns() public view returns (uint256) {
        uint256 cumulativeDeployedAmount = getCumulativeDeployedAmount();
        if (cumulativeDeployedAmount == 0) {
            return 0;
        }
        return
            (100 * PERCENTAGE_DECIMAL * getCumulativeDividends()) /
            cumulativeDeployedAmount;
    }
}
