// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "./external/ERC721PresetMinterPauserAutoIdUpgradeable.sol";
import "./ProtocolConfig.sol";

/**
    A warrant token is an ERC721 token that grants the owner the right to withdraw dividends
    from the pool. This contract draws heavily from Goldfinch's design, which has been audited by Certik
    https://github.com/goldfinch-eng/goldfinch-contracts/blob/55a7799bd7d30778bc026ab6b4f9b956115c76ff/v2.0/protocol/core/PoolTokens.sol
 */

contract WarrantToken is ERC721PresetMinterPauserAutoIdUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    // token id -> token info struct
    mapping(uint256 => TokenInfo) public tokens;

    struct TokenInfo {
        address pool; // the pool that issued the token
        ProtocolConfig.PoolType poolType;
    }

    event TokenMinted(
        address indexed owner,
        address indexed pool,
        uint256 indexed tokenId
    );

    event TokenBurned(
        address indexed owner,
        address indexed pool,
        uint256 indexed tokenId
    );

    function initialize(address owner) external initializer {
        require(
            owner != address(0),
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

        _setupRole(PAUSER_ROLE, owner);
        _setupRole(OWNER_ROLE, owner);

        _setRoleAdmin(PAUSER_ROLE, OWNER_ROLE);
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
    }

    /**
     * @notice Called by pool to create a warrant token
     * @param to The address that should own the warrant token
     * @return tokenId The token ID (auto-incrementing integer across all pools)
     */
    function mint(
        address to,
        address poolAddress,
        ProtocolConfig.PoolType poolType
    ) external virtual whenNotPaused returns (uint256 tokenId) {
        tokenId = createToken(poolAddress, poolType);
        _mint(to, tokenId);
        emit TokenMinted(to, poolAddress, tokenId);
        return tokenId;
    }

    function createToken(
        address poolAddress,
        ProtocolConfig.PoolType newPoolType
    ) internal returns (uint256 tokenId) {
        _tokenIdTracker.increment();
        tokenId = _tokenIdTracker.current();
        tokens[tokenId] = TokenInfo({pool: poolAddress, poolType: newPoolType});
        return tokenId;
    }

    function burn(uint256 tokenId) external virtual whenNotPaused {
        TokenInfo memory token = tokens[tokenId];
        bool canBurn = _isApprovedOrOwner(_msgSender(), tokenId);
        address owner = ownerOf(tokenId);
        require(
            canBurn || token.pool != address(0),
            "ERC721Burnable: caller cannot burn this token"
        );
        destroyAndBurn(tokenId);
        emit TokenBurned(owner, token.pool, tokenId);
    }

    // Returns a token ID owned by owner at a given index of its token list.
    // Use along with balanceOf to enumerate all of owner's tokens.
    function getTokensByOwner(address owner)
        external
        view
        returns (uint256[] memory tokenIds)
    {
        uint256[] memory result = new uint256[](balanceOf(owner));
        for (uint256 i = 0; i < balanceOf(owner); i++) {
            result[i] = tokenOfOwnerByIndex(owner, i);
        }
        return result;
    }

    function getTokensByOwnerAndPoolAddress(
        address owner,
        address pool,
        ProtocolConfig.PoolType poolType
    ) external view returns (uint256[] memory tokenIds) {
        uint256[] memory result = new uint256[](balanceOf(owner));
        for (uint256 i = 0; i < balanceOf(owner); i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, i);
            if (
                tokens[tokenId].pool == pool &&
                tokens[tokenId].poolType == poolType
            ) {
                result[i] = tokenId;
            }
        }
        return result;
    }

    function destroyAndBurn(uint256 tokenId) internal {
        delete tokens[tokenId];
        _burn(tokenId);
    }

    function getPool(uint256 tokenId) external view returns (address pool) {
        TokenInfo memory token = tokens[tokenId];
        return token.pool;
    }

    function getPoolType(uint256 tokenId)
        external
        view
        returns (ProtocolConfig.PoolType poolType)
    {
        TokenInfo memory token = tokens[tokenId];
        return token.poolType;
    }
}
