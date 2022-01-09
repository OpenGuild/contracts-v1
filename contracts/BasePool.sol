// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./external/BaseUpgradeablePausable.sol";
import "./WarrantToken.sol";
import "./ProtocolConfig.sol";

abstract contract BasePool is BaseUpgradeablePausable {
    // --- IAM roles ------------------
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");

    // Precision of allocation percentages- (1 percent == PERCENTAGE_DECIMAL)
    uint256 public constant PERCENTAGE_DECIMAL = 10**16;

    // ERC20 token that the pool is denominated in
    IERC20Upgradeable public poolToken;

    // ERC721 token that grants the owner the right to withdraw dividends from the pool
    WarrantToken public warrantToken;

    ProtocolConfig internal config;

    ProtocolConfig.PoolType public poolType;

    event WithdrawInvestment(address indexed from, uint256 amount);
    event DepositContribution(address indexed from, uint256 amount);

    event Invest(uint256 tokenId, address indexed from, uint256 amount);
    event Claim(address indexed from, uint256 amount);

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

        _setRoleAdmin(INVESTOR_ROLE, OWNER_ROLE);
    }

    function addInvestor(address investorAddress)
        external
        onlyRole(OWNER_ROLE)
    {
        grantRole(INVESTOR_ROLE, investorAddress);
    }

    function removeInvestor(address investorAddress)
        external
        onlyRole(OWNER_ROLE)
    {
        revokeRole(INVESTOR_ROLE, investorAddress);
    }

    // Given an amount, returns a tuple of OpenGuild's take + remainder
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

    // Returns the sum of all dividends returned to this pool
    function getCumulativeDividends() public view virtual returns (uint256) {}

    // Returns the returns for a token
    function getReturnsForToken(uint256 tokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the returns for a token
    function getTokenTotalDividends(uint256 tokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the returns for a token
    function getTokenUnclaimedDividends(uint256 tokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the deployed amount for a token
    function getTokenDeployedAmount(uint256 tokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the undeployed amount for a token
    function getUndeployedAmountForWarrantToken(uint256 tokenId)
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the total undeployed amount for a pool
    function getTotalUndeployedAmount()
        external
        view
        virtual
        returns (uint256)
    {}

    // Returns the sum of all investments deployed in this pool
    function getCumulativeDeployedAmount()
        public
        view
        virtual
        returns (uint256)
    {}

    // Returns the cumulative cash on cash returns of the current pool, to the same
    // digits of precision as the poolToken
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
