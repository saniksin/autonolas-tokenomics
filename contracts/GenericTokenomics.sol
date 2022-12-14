/// This file is auto-generated by Scribble and shouldn't be edited directly.
/// Use --disarm prior to make any changes.
pragma solidity ^0.8.17;

import "./interfaces/IErrorsTokenomics.sol";
import "hardhat/node_modules/ansi-colors/__scribble_ReentrancyUtils.sol";

/// @title GenericTokenomics - Smart contract for generic tokenomics contract template
///  @author AL
///  @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
abstract contract GenericTokenomics is __scribble_ReentrancyUtils, IErrorsTokenomics {
    enum TokenomicsRole { Tokenomics, Treasury, Depository, Dispenser }

    event OwnerUpdated(address indexed owner);

    event TokenomicsUpdated(address indexed tokenomics);

    event TreasuryUpdated(address indexed treasury);

    event DepositoryUpdated(address indexed depository);

    event DispenserUpdated(address indexed dispenser);

    address public constant SENTINEL_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    bytes32 public constant PROXY_TOKENOMICS = 0xbd5523e7c3b6a94aa0e3b24d1120addc2f95c7029e097b466b2bedc8d4b4362f;
    uint8 internal _locked;
    TokenomicsRole public tokenomicsRole;
    address public owner;
    address public olas;
    address public tokenomics;
    address public treasury;
    address public depository;
    address public dispenser;

    /// @dev Generic Tokenomics initializer.
    ///  @param _olas OLAS token address.
    ///  @param _tokenomics Tokenomics address.
    ///  @param _treasury Treasury address.
    ///  @param _depository Depository address.
    ///  @param _dispenser Dispenser address.
    function initialize(address _olas, address _tokenomics, address _treasury, address _depository, address _dispenser, TokenomicsRole _tokenomicsRole) internal {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }
        _locked = 1;
        olas = _olas;
        tokenomics = _tokenomics;
        treasury = _treasury;
        depository = _depository;
        dispenser = _dispenser;
        tokenomicsRole = _tokenomicsRole;
        owner = msg.sender;
    }

    function changeOwner(address newOwner) virtual external {
        __scribble_out_of_contract = false;
        _original_GenericTokenomics_changeOwner(newOwner);
        __scribble_check_state_invariants();
        __scribble_out_of_contract = true;
    }

    function _original_GenericTokenomics_changeOwner(address newOwner) private {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function changeManagers(address _tokenomics, address _treasury, address _depository, address _dispenser) external {
        __scribble_out_of_contract = false;
        _original_GenericTokenomics_changeManagers(_tokenomics, _treasury, _depository, _dispenser);
        __scribble_check_state_invariants();
        __scribble_out_of_contract = true;
    }

    function _original_GenericTokenomics_changeManagers(address _tokenomics, address _treasury, address _depository, address _dispenser) private {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        if ((_tokenomics != address(0)) && (tokenomicsRole != TokenomicsRole.Tokenomics)) {
            tokenomics = _tokenomics;
            emit TokenomicsUpdated(_tokenomics);
        }
        if ((_treasury != address(0)) && (tokenomicsRole != TokenomicsRole.Treasury)) {
            treasury = _treasury;
            emit TreasuryUpdated(_treasury);
        }
        if (((_depository != address(0)) && (tokenomicsRole != TokenomicsRole.Depository)) && (tokenomicsRole != TokenomicsRole.Dispenser)) {
            depository = _depository;
            emit DepositoryUpdated(_depository);
        }
        if (((_dispenser != address(0)) && (tokenomicsRole != TokenomicsRole.Dispenser)) && (tokenomicsRole != TokenomicsRole.Depository)) {
            dispenser = _dispenser;
            emit DispenserUpdated(_dispenser);
        }
    }

    /// Check only the current contract's state invariants
    function __scribble_GenericTokenomics_check_state_invariants_internal() internal {}

    /// Check the state invariant for the current contract and all its bases
    function __scribble_check_state_invariants() virtual internal {
        __scribble_GenericTokenomics_check_state_invariants_internal();
    }

    constructor() {
        __scribble_out_of_contract = false;
        __scribble_check_state_invariants();
        __scribble_out_of_contract = true;
    }
}