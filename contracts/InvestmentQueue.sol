// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "./external/BaseUpgradeablePausable.sol";
import "./ProtocolConfig.sol";

struct Investment {
    uint256 tokenId;
    uint256 amount;
    uint256 createdAt;
}

library InvestmentFunctions {
    function isNull(Investment memory node) internal pure returns (bool) {
        return node.createdAt == 0;
    }
}

contract InvestmentQueue is BaseUpgradeablePausable {
    using InvestmentFunctions for Investment;

    // maps queue position to Investment struct
    mapping(uint256 => Investment) public queue;
    // maps from tokenId to queue position
    mapping(uint256 => uint256) public tokenIdToPosition;
    // current first position of the queue
    uint256 public first;
    // current last position of the queue
    uint256 public last;
    // total amount of currency invested into the queue
    uint256 public totalAmount;

    ProtocolConfig public config;

    address recipient;

    function initialize(
        address _owner,
        ProtocolConfig _config,
        // Adding this to prevent deploy script from making multiple InvestmentQueue deployments to the same recipient
        address _recipient
    ) public initializer {
        require(_recipient != address(0), "Recipient cannot be the 0x address");

        __BaseUpgradeablePausable__init(_owner);
        config = _config;
        first = 1;
        last = 0;
        recipient = _recipient;
    }

    modifier onlyIndividualPoolOrOwner() {
        require(
            isAdmin() || config.isValidIndividualPool(_msgSender()),
            "Queue functions must be called from valid individual pools"
        );
        _;
    }

    modifier onlyPoolOrOwner() {
        require(
            isAdmin() ||
                config.isValidIndividualPool(_msgSender()) ||
                config.isValidAggregatePool(_msgSender()),
            "Queue functions must be called from a valid individual or aggregate pool"
        );
        _;
    }

    function isEmpty() public view returns (bool) {
        return last < first;
    }

    function peek() public view returns (Investment memory) {
        require(!isEmpty(), "Queue cannot be empty");

        return queue[first];
    }

    function enqueue(
        uint256 tokenId,
        uint256 amount,
        uint256 createdAt
    ) external onlyPoolOrOwner {
        require(amount > 0, "Cannot enqueue a node without an amount");

        Investment memory node = Investment(tokenId, amount, createdAt);
        last += 1;
        queue[last] = node;
        tokenIdToPosition[tokenId] = last;
        totalAmount += node.amount;
    }

    function dequeue()
        public
        onlyIndividualPoolOrOwner
        returns (Investment memory)
    {
        require(!isEmpty(), "Queue cannot be empty");
        assert(exists(first));

        Investment memory node = queue[first];
        delete queue[first];
        totalAmount -= node.amount;
        first += 1;
        delete tokenIdToPosition[node.tokenId];
        // nodes between first and last, excluding the first, could have been deleted
        while (!isEmpty() && peek().isNull()) {
            first += 1;
        }
        return node;
    }

    function get(uint256 index) external view returns (Investment memory) {
        require(
            exists(index),
            "Node does not exist; it might have been removed"
        );
        return queue[index];
    }

    function remove(uint256 index)
        external
        onlyIndividualPoolOrOwner
        returns (Investment memory)
    {
        require(
            index >= first && index <= last,
            "Index to be removed out of bounds"
        );
        require(exists(index), "Node at index must exist");

        if (index == first) {
            return dequeue();
        }
        Investment memory node = queue[index];
        delete queue[index];
        delete tokenIdToPosition[node.tokenId];
        totalAmount -= node.amount;
        return node;
    }

    function exists(uint256 index) public view returns (bool) {
        return !queue[index].isNull();
    }

    function decrementAmountAtHead(uint256 amount)
        external
        onlyIndividualPoolOrOwner
    {
        require(!isEmpty(), "Queue cannot be empty");
        require(
            queue[first].amount > amount,
            "Can't decrement more than amount at head"
        );
        queue[first].amount -= amount;
        totalAmount -= amount;
    }

    function getAmountFromTokenId(uint256 tokenId)
        external
        view
        returns (uint256)
    {
        uint256 position = tokenIdToPosition[tokenId];
        Investment memory investment = queue[position];
        return investment.amount;
    }
}
