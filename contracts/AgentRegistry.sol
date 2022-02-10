// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IRegistry.sol";

/// @title Agent Registry - Smart contract for registering agents
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
contract AgentRegistry is IMultihash, ERC721Enumerable, Ownable, ReentrancyGuard {
    // Agent parameters
    struct Agent {
        // Developer of the agent
        address developer;
        // IPFS hash of the agent
        Multihash[] agentHashes; // can be obtained via mapping, consider for optimization
        // Description of the agent
        string description;
        // Set of component dependencies
        uint256[] dependencies;
        // Agent activity
        bool active;
    }

    // Component registry
    address public immutable componentRegistry;
    // Base URI
    string public _BASEURI;
    // Agent counter
    uint256 private _tokenIds;
    // Agent manager
    address private _manager;
    // Map of token Id => component
    mapping(uint256 => Agent) private _mapTokenIdAgent;
    // Map of IPFS hash => token Id
    mapping(bytes32 => uint256) private _mapHashTokenId;

    // name = "agent", symbol = "MECH"
    constructor(string memory _name, string memory _symbol, string memory _bURI, address _componentRegistry)
        ERC721(_name, _symbol) {
        _BASEURI = _bURI;
        componentRegistry = _componentRegistry;
    }

    // Only the manager has a privilege to manipulate an agent
    modifier onlyManager {
        require(_manager == msg.sender, "agentManager: MANAGER_ONLY");
        _;
    }

    // Checks for supplied IPFS hash
    modifier checkHash(Multihash memory hashStruct) {
        // Check hash IPFS current standard validity
        require(hashStruct.hashFunction == 0x12 && hashStruct.size == 0x20, "checkHash: WRONG_HASH");
        // Check for the existent IPFS hashes
        require(_mapHashTokenId[hashStruct.hash] == 0, "checkHash: HASH_EXISTS");
        _;
    }

    /// @dev Changes the agent manager.
    /// @param newManager Address of a new agent manager.
    function changeManager(address newManager) public onlyOwner {
        _manager = newManager;
    }

    /// @dev Set the agent data.
    /// @param tokenId Token / agent Id.
    /// @param developer Developer of the agent.
    /// @param agentHash IPFS hash of the agent.
    /// @param description Description of the agent.
    /// @param dependencies Set of component dependencies.
    function _setAgentInfo(uint256 tokenId, address developer, Multihash memory agentHash,
        string memory description, uint256[] memory dependencies)
        private
    {
        Agent storage agent = _mapTokenIdAgent[tokenId];
        agent.developer = developer;
        agent.agentHashes.push(agentHash);
        agent.description = description;
        agent.dependencies = dependencies;
        agent.active = true;
        _mapHashTokenId[agentHash.hash] = tokenId;
    }

    /// @dev Creates agent.
    /// @param owner Owner of the agent.
    /// @param developer Developer of the agent.
    /// @param agentHash IPFS hash of the agent.
    /// @param description Description of the agent.
    /// @param dependencies Set of component dependencies in a sorted ascending order.
    /// @return The id of a minted agent.
    function create(address owner, address developer, Multihash memory agentHash, string memory description,
        uint256[] memory dependencies)
        external
        onlyManager
        checkHash(agentHash)
        nonReentrant
        returns (uint256)
    {
        // Checks for owner and developer being not zero addresses
        require(owner != address(0) && developer != address(0), "create: ZERO_ADDRESS");

        // Checks for non-empty description and component dependency
        require(bytes(description).length > 0, "create: NO_DESCRIPTION");
//        require(dependencies.length > 0, "Agent must have at least one component dependency");

        // Check for dependencies validity: must be already allocated, must not repeat
        uint256 lastId = 0;
        for (uint256 iDep = 0; iDep < dependencies.length; iDep++) {
            require(dependencies[iDep] > lastId && IRegistry(componentRegistry).exists(dependencies[iDep]),
                "create: WRONG_COMPONENT_ID");
            lastId = dependencies[iDep];
        }

        // Mint token and initialize the component
        _tokenIds++;
        uint256 newTokenId = _tokenIds;
        _setAgentInfo(newTokenId, developer, agentHash, description, dependencies);
        _safeMint(owner, newTokenId);

        return newTokenId;
    }

    /// @dev Updates the agent hash.
    /// @param owner Owner of the agent.
    /// @param tokenId Token Id.
    /// @param agentHash New IPFS hash of the agent.
    function updateHash(address owner, uint256 tokenId, Multihash memory agentHash)
        external
        onlyManager
        checkHash(agentHash)
    {
        require(ownerOf(tokenId) == owner, "update: AGENT_NOT_FOUND");
        Agent storage agent = _mapTokenIdAgent[tokenId];
        agent.agentHashes.push(agentHash);
    }

    /// @dev Check for the token / agent existence.
    /// @param tokenId Token Id.
    /// @return true if the agent exists, false otherwise.
    function exists (uint256 tokenId) public view returns (bool) {
        return _exists(tokenId);
    }

    /// @dev Gets the agent info.
    /// @param tokenId Token Id.
    /// @return owner Owner of the agent.
    /// @return developer The agent developer.
    /// @return agentHash The primary agent IPFS hash.
    /// @return description The agent description.
    /// @return numDependencies The number of components in the dependency list.
    /// @return dependencies The list of component dependencies.
    function getInfo(uint256 tokenId)
        public
        view
        returns (address owner, address developer, Multihash memory agentHash, string memory description,
            uint256 numDependencies, uint256[] memory dependencies)
    {
        require(_exists(tokenId), "getComponentInfo: NO_AGENT");
        Agent storage agent = _mapTokenIdAgent[tokenId];
        return (ownerOf(tokenId), agent.developer, agent.agentHashes[0], agent.description, agent.dependencies.length,
            agent.dependencies);
    }

    /// @dev Gets agent hashes.
    /// @param tokenId Token Id.
    /// @return numHashes Number of hashes.
    /// @return agentHashes The list of agent hashes.
    function getHashes(uint256 tokenId) public view returns (uint256 numHashes, Multihash[] memory agentHashes) {
        require(_exists(tokenId), "getHashes: NO_AGENT");
        Agent storage agent = _mapTokenIdAgent[tokenId];
        return (agent.agentHashes.length, agent.agentHashes);
    }

    /// @dev Returns agent base URI.
    /// @return base URI string.
    function _baseURI() internal view override returns (string memory) {
        return _BASEURI;
    }

    /// @dev Returns agent base URI.
    /// @return base URI string.
    function getBaseURI() public view returns (string memory) {
        return _baseURI();
    }

    /// @dev Sets agent base URI.
    /// @param bURI base URI string.
    function setBaseURI(string memory bURI) public onlyOwner {
        _BASEURI = bURI;
    }
}
