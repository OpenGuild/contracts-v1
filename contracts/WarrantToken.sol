// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "./external/ERC721PresetMinterPauserAutoIdUpgradeable.sol";
import "./ProtocolConfig.sol";

/**
 * @title WarrantToken
 * @notice  A warrant token is an ERC721 token that grants the owner the right to withdraw dividends from the pool.
 * @notice This contract draws heavily from Goldfinch's design, which has been audited by Certik.
 * @notice https://github.com/goldfinch-eng/goldfinch-contracts/blob/55a7799bd7d30778bc026ab6b4f9b956115c76ff/v2.0/protocol/core/PoolTokens.sol
 */
contract WarrantToken is ERC721PresetMinterPauserAutoIdUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    // --- IAM Roles ------------------
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    // warrant token id => warrant token info struct
    mapping(uint256 => WarrantTokenInfo) public warrantTokens;

    // This struct contains information about the investor's warrant token
    struct WarrantTokenInfo {
        // the pool that issued the warrant token
        address pool;
        ProtocolConfig.PoolType poolType;
    }

    event WarrantTokenMinted(
        address indexed owner,
        address indexed pool,
        uint256 indexed warrantTokenId
    );
    event WarrantTokenBurned(
        address indexed owner,
        address indexed pool,
        uint256 indexed warrantTokenId
    );

    /**
     * @notice Run only once, on initialization
     * @param _owner The address that is assigned the "OWNER_ROLE" of this contract
     */
    function initialize(address _owner) external initializer {
        require(
            _owner != address(0),
            "Owner and config addresses cannot be empty"
        );

        __Context_init_unchained();
        __AccessControlEnumerable_init_unchained();
        __ERC165_init_unchained();
        // This is setting name and symbol of the NFT's
        __ERC721_init_unchained(
            "OpenGuild V1 Income Share Pool Tokens",
            "OG-V1-ISAPT"
        );
        __Pausable_init_unchained();
        __ERC721Pausable_init_unchained();

        _setupRole(PAUSER_ROLE, _owner);
        _setupRole(OWNER_ROLE, _owner);

        _setRoleAdmin(PAUSER_ROLE, OWNER_ROLE);
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
    }

    /**
     * @notice Called by a pool to create a warrant token
     * @param to The address that should own the warrant token
     * @param poolAddress The pool that issued this warrant token
     * @param poolType The pool type of the pool that issued this warrant token
     * @return The warrant token ID (auto-incrementing integer across all pools)
     */
    function mint(
        address to,
        address poolAddress,
        ProtocolConfig.PoolType poolType
    ) external virtual whenNotPaused returns (uint256) {
        uint256 warrantTokenId = createWarrantToken(poolAddress, poolType);
        _mint(to, warrantTokenId);
        emit WarrantTokenMinted(to, poolAddress, warrantTokenId);
        return warrantTokenId;
    }

    /**
     * @notice Creates a new warrant token and corresponding WarrantTokenInfo struct
     * @param poolAddress The pool that issued this warrant token
     * @param newPoolType The pool type of the pool that issued this warrant token
     * @return The warrant token ID (auto-incrementing integer across all pools)
     */
    function createWarrantToken(
        address poolAddress,
        ProtocolConfig.PoolType newPoolType
    ) internal returns (uint256) {
        _warrantTokenIdTracker.increment();
        uint256 warrantTokenId = _warrantTokenIdTracker.current();
        warrantTokens[warrantTokenId] = WarrantTokenInfo({
            pool: poolAddress,
            poolType: newPoolType
        });
        return warrantTokenId;
    }

    /**
     * @return All of the warrant token IDs that the owners own
     * @notice Use along with balanceOf to enumerate all of owner's warrant tokens.
     * @param owner The address of the owner
     */
    function getWarrantTokensByOwner(address owner)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory result = new uint256[](balanceOf(owner));
        for (uint256 i = 0; i < balanceOf(owner); i++) {
            result[i] = tokenOfOwnerByIndex(owner, i);
        }
        return result;
    }

    /**
     * @notice Burns a warrant token
     * @param warrantTokenId The ID of the warrant token to burn
     */
    function burn(uint256 warrantTokenId) external virtual whenNotPaused {
        WarrantTokenInfo memory warrantToken = warrantTokens[warrantTokenId];
        bool canBurn = _isApprovedOrOwner(_msgSender(), warrantTokenId);
        address owner = ownerOf(warrantTokenId);
        require(
            canBurn || warrantToken.pool != address(0),
            "ERC721Burnable: caller cannot burn this warrant token"
        );
        destroyAndBurn(warrantTokenId);
        emit WarrantTokenBurned(owner, warrantToken.pool, warrantTokenId);
    }

    /**
     * @notice Burns a warrant token and deletes (destroys) it from the warrant tokens mapping
     * @param warrantTokenId The ID of the warrant token to destory and burn
     */
    function destroyAndBurn(uint256 warrantTokenId) internal {
        delete warrantTokens[warrantTokenId];
        _burn(warrantTokenId);
    }

    /**
     * @return All of the warrant token IDs that the owners own in a given pool
     * @notice Use along with balanceOf to enumerate all of owner's warrant tokens.
     * @param owner The address of the owner
     * @param pool The pool of the warrant tokens to return
     * @param poolType The pool type of the given pool
     */
    function getWarrantTokensByOwnerAndPoolAddress(
        address owner,
        address pool,
        ProtocolConfig.PoolType poolType
    ) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](balanceOf(owner));
        for (uint256 i = 0; i < balanceOf(owner); i++) {
            uint256 warrantTokenId = tokenOfOwnerByIndex(owner, i);
            if (
                warrantTokens[warrantTokenId].pool == pool &&
                warrantTokens[warrantTokenId].poolType == poolType
            ) {
                result[i] = warrantTokenId;
            }
        }
        return result;
    }
}
