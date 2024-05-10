// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IErrorsTokenomics} from "./interfaces/IErrorsTokenomics.sol";
import {IToken} from "./interfaces/IToken.sol";
import {ITokenomics} from "./interfaces/ITokenomics.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

interface IVoteWeighting {
    struct Nominee {
        bytes32 account;
        uint256 chainId;
    }

    function checkpointNominee(bytes32 account, uint256 chainId) external;
    function nomineeRelativeWeight(bytes32 account, uint256 chainId, uint256 time) external view returns (uint256, uint256);
}

interface ITokenomicsInfo {
    // Structure for epoch point with tokenomics-related statistics during each epoch
    // The size of the struct is 96 * 2 + 64 + 32 * 2 + 8 * 2 = 256 + 80 (2 slots)
    struct EpochPoint {
        // Total amount of ETH donations accrued by the protocol during one epoch
        // Even if the ETH inflation rate is 5% per year, it would take 130+ years to reach 2^96 - 1 of ETH total supply
        uint96 totalDonationsETH;
        // Amount of OLAS intended to fund top-ups for the epoch based on the inflation schedule
        // After 10 years, the OLAS inflation rate is 2% per year. It would take 220+ years to reach 2^96 - 1
        uint96 totalTopUpsOLAS;
        // Inverse of the discount factor
        // IDF is bound by a factor of 18, since (2^64 - 1) / 10^18 > 18
        // IDF uses a multiplier of 10^18 by default, since it is a rational number and must be accounted for divisions
        // The IDF depends on the epsilonRate value, idf = 1 + epsilonRate, and epsilonRate is bound by 17 with 18 decimals
        uint64 idf;
        // Number of new owners
        // Each unit has at most one owner, so this number cannot be practically bigger than numNewUnits
        uint32 numNewOwners;
        // Epoch end timestamp
        // 2^32 - 1 gives 136+ years counted in seconds starting from the year 1970, which is safe until the year of 2106
        uint32 endTime;
        // Parameters for rewards and top-ups (in percentage)
        // Each of these numbers cannot be practically bigger than 100 as they sum up to 100%
        // treasuryFraction + rewardComponentFraction + rewardAgentFraction = 100%
        // Treasury fraction
        uint8 rewardTreasuryFraction;
        // maxBondFraction + topUpComponentFraction + topUpAgentFraction <= 100%
        // Amount of OLAS (in percentage of inflation) intended to fund bonding incentives during the epoch
        uint8 maxBondFraction;
    }

    // Struct for service staking epoch info
    struct StakingPoint {
        // Amount of OLAS that funds service staking for the epoch based on the inflation schedule
        // After 10 years, the OLAS inflation rate is 2% per year. It would take 220+ years to reach 2^96 - 1
        uint96 stakingAmount;
        // Max allowed service staking amount threshold
        // This value is never bigger than the stakingAmount
        uint96 maxStakingAmount;
        // Service staking vote weighting threshold
        uint16 minStakingWeight;
        // Service staking fraction
        // This number cannot be practically bigger than 100 as it sums up to 100% with others
        // maxBondFraction + topUpComponentFraction + topUpAgentFraction + stakingFraction <= 100%
        uint8 stakingFraction;
    }

    function epochCounter() external view returns (uint32);
    // TODO Create a better getter in Tokenomics
    function mapEpochTokenomics(uint256 eCounter) external view returns (EpochPoint memory);
    function mapEpochStakingPoints(uint256 eCounter) external view returns (StakingPoint memory);
    function refundFromStaking(uint256 amount) external;
}

interface IDepositProcessor {
    function sendMessage(address target, uint256 stakingAmount, bytes memory bridgePayload,
        uint256 transferAmount) external payable;
    function sendMessageBatch(address[] memory targets, uint256[] memory stakingAmounts, bytes[] memory bridgePayloads,
        uint256 transferAmount) external payable;
    function sendMessageNonEVM(bytes32 target, uint256 stakingAmount, bytes memory bridgePayload,
        uint256 transferAmount) external payable;
    function sendMessageBatchNonEVM(bytes32[] memory targets, uint256[] memory stakingAmounts,
        bytes[] memory bridgePayloads, uint256 transferAmount) external payable;
    function getBridgingDecimals() external pure returns (uint256);
}

/// @dev Only the deposit processor is able to call the function.
/// @param sender Actual sender address.
/// @param depositProcessor Required deposit processor.
error DepositProcessorOnly(address sender, address depositProcessor);

// TODO Names and titles in all the deployed contracts
/// @title Dispenser - Smart contract for distributing incentives
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
contract Dispenser is IErrorsTokenomics {
    event OwnerUpdated(address indexed owner);
    event TokenomicsUpdated(address indexed tokenomics);
    event TreasuryUpdated(address indexed treasury);
    event VoteWeightingUpdated(address indexed voteWeighting);
    event IncentivesClaimed(address indexed owner, uint256 reward, uint256 topUp);
    event StakingIncentivesClaimed(address indexed account, uint256 stakingAmount, uint256 returnAmount);
    event SetDepositProcessorChainIds(address[] depositProcessors, uint256[] chainIds);
    event WithheldAmountSynced(uint256 chainId, uint256 amount);

    enum Pause {
        Unpaused,
        DevIncentivesPaused,
        StakingIncentivesPaused,
        AllPaused
    }

    // Maximum chain Id as per EVM specs
    uint256 public constant MAX_EVM_CHAIN_ID = type(uint64).max / 2 - 36;

    // OLAS token address
    address public immutable olas;

    // Max number of epochs to claim staking incentives for
    uint256 public maxNumClaimingEpochs;
    // Max number of targets for a specific chain to claim staking incentives for
    uint256 public maxNumStakingTargets;
    // Owner address
    address public owner;
    // Reentrancy lock
    uint8 internal _locked;
    // Pause state
    Pause public paused;

    // Tokenomics contract address
    address public tokenomics;
    // Treasury contract address
    address public treasury;
    // Vote Weighting contract address
    address public voteWeighting;
    // Retainer address
    address public retainer;

    // Mapping for hash(Nominee struct) service staking pair => last claimed epochs
    mapping(bytes32 => uint256) public mapLastClaimedStakingServiceEpochs;
    // Mapping for hash(Nominee struct) service staking pair => epoch number when the staking contract is removed
    mapping(bytes32 => uint256) public mapRemovedNomineeEpochs;
    // Mapping for L2 chain Id => dedicated deposit processors
    mapping(uint256 => address) public mapChainIdDepositProcessors;
    // Mapping for L2 chain Id => withheld OLAS amounts
    mapping(uint256 => uint256) public mapChainIdWithheldAmounts;

    /// @dev Dispenser constructor.
    /// @param _tokenomics Tokenomics address.
    /// @param _treasury Treasury address.
    /// @param _voteWeighting Vote Weighting address.
    constructor(address _tokenomics, address _treasury, address _voteWeighting)
    {
        owner = msg.sender;
        _locked = 1;
        // TODO Define final behavior before deployment
        paused = Pause.StakingIncentivesPaused;

        // Check for at least one zero contract address
        if (_tokenomics == address(0) || _treasury == address(0) || _voteWeighting == address(0)) {
            revert ZeroAddress();
        }

        tokenomics = _tokenomics;
        treasury = _treasury;
        voteWeighting = _voteWeighting;
        // TODO initial max number of epochs to claim staking incentives for
        maxNumClaimingEpochs = 10;
    }

    /// @dev Changes the owner address.
    /// @param newOwner Address of a new owner.
    function changeOwner(address newOwner) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the zero address
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    /// @dev Changes various managing contract addresses.
    /// @param _tokenomics Tokenomics address.
    /// @param _treasury Treasury address.
    /// @param _voteWeighting Vote Weighting address.
    function changeManagers(address _tokenomics, address _treasury, address _voteWeighting) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Change Tokenomics contract address
        if (_tokenomics != address(0)) {
            tokenomics = _tokenomics;
            emit TokenomicsUpdated(_tokenomics);
        }

        // Change Treasury contract address
        if (_treasury != address(0)) {
            treasury = _treasury;
            emit TreasuryUpdated(_treasury);
        }

        // Change Vote Weighting contract address
        if (_voteWeighting != address(0)) {
            voteWeighting = _voteWeighting;
            emit VoteWeightingUpdated(_voteWeighting);
        }
    }

    function changeRetainer(address _retainer) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        retainer = _retainer;
    }

    function changeStakingParams(uint256 _maxNumClaimingEpochs, uint256 _maxNumStakingTargets) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (_maxNumClaimingEpochs > 0) {
            maxNumClaimingEpochs = _maxNumClaimingEpochs;
        }

        if (_maxNumStakingTargets > 0) {
            maxNumStakingTargets = _maxNumStakingTargets;
        }
    }

    /// @dev Records nominee starting epoch number.
    /// @param nomineeHash Nominee hash.
    function enableNominee(bytes32 nomineeHash) external {
        // Check for the contract ownership
        if (msg.sender != voteWeighting) {
            revert ManagerOnly(msg.sender, voteWeighting);
        }

        mapLastClaimedStakingServiceEpochs[nomineeHash] = ITokenomicsInfo(tokenomics).epochCounter();
    }

    /// @dev Records nominee removal epoch number.
    /// @param nomineeHash Nominee hash.
    function removeNominee(bytes32 nomineeHash) external {
        // Check for the contract ownership
        if (msg.sender != voteWeighting) {
            revert ManagerOnly(msg.sender, voteWeighting);
        }

        mapRemovedNomineeEpochs[nomineeHash] = ITokenomicsInfo(tokenomics).epochCounter();
    }

    // TODO Implement the retaining logic based on staking amounts calculations
    function retain() external {
        // Go over epochs and retain funds to return back to the tokenomics
    }

    /// @dev Claims incentives for the owner of components / agents.
    /// @notice `msg.sender` must be the owner of components / agents they are passing, otherwise the function will revert.
    /// @notice If not all `unitIds` belonging to `msg.sender` were provided, they will be untouched and keep accumulating.
    /// @param unitTypes Set of unit types (component / agent).
    /// @param unitIds Set of corresponding unit Ids where account is the owner.
    /// @return reward Reward amount in ETH.
    /// @return topUp Top-up amount in OLAS.
    function claimOwnerIncentives(uint256[] memory unitTypes, uint256[] memory unitIds) external
        returns (uint256 reward, uint256 topUp)
    {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        Pause currentPause = paused;
        if (currentPause == Pause.DevIncentivesPaused || currentPause == Pause.AllPaused) {
            revert();
        }

        // Calculate incentives
        (reward, topUp) = ITokenomics(tokenomics).accountOwnerIncentives(msg.sender, unitTypes, unitIds);

        bool success;
        // Request treasury to transfer funds to msg.sender if reward > 0 or topUp > 0
        if ((reward + topUp) > 0) {
            success = ITreasury(treasury).withdrawToAccount(msg.sender, reward, topUp);
        }

        // Check if the claim is successful and has at least one non-zero incentive.
        if (!success) {
            revert ClaimIncentivesFailed(msg.sender, reward, topUp);
        }

        emit IncentivesClaimed(msg.sender, reward, topUp);

        _locked = 1;
    }

    function _distribute(
        uint256 chainId,
        bytes32 stakingTarget,
        uint256 stakingAmount,
        bytes memory bridgePayload,
        uint256 transferAmount
    ) internal {
        // Get the deposit processor contract address
        address depositProcessor = mapChainIdDepositProcessors[chainId];

        // Transfer corresponding OLAS amounts to the deposit processor
        IToken(olas).transfer(depositProcessor, transferAmount);

        if (chainId <= MAX_EVM_CHAIN_ID) {
            address stakingTargetEVM = address(uint160(uint256(stakingTarget)));
            IDepositProcessor(depositProcessor).sendMessage{value:msg.value}(stakingTargetEVM, stakingAmount,
                bridgePayload, transferAmount);
        } else {
            // Send to non-EVM
            IDepositProcessor(depositProcessor).sendMessageNonEVM{value:msg.value}(stakingTarget,
                stakingAmount, bridgePayload, transferAmount);
        }
    }

    function _distributeBatch(
        uint256[] memory chainIds,
        bytes32[][] memory stakingTargets,
        uint256[][] memory stakingAmounts,
        bytes[] memory bridgePayloads,
        uint256[] memory transferAmounts
    ) internal {
        // Traverse all staking targets
        for (uint256 i = 0; i < chainIds.length; ++i) {
            // Unpack chain Id and target addresses
            uint256 chainId = chainIds[i];
            // Get the deposit processor contract address
            address depositProcessor = mapChainIdDepositProcessors[chainId];
            // Transfer corresponding OLAS amounts to deposit processors
            IToken(olas).transfer(depositProcessor, transferAmounts[i]);

            if (chainId <= MAX_EVM_CHAIN_ID) {
                address[] memory stakingTargetsEVM = new address[](stakingTargets[i].length);
                for (uint256 j = 0; j < stakingTargets[i].length; ++j) {
                    stakingTargetsEVM[j] = address(uint160(uint256(stakingTargets[i][j])));
                }
                // Send to EVM chains
                IDepositProcessor(depositProcessor).sendMessageBatch{value:msg.value}(stakingTargetsEVM,
                    stakingAmounts[i], bridgePayloads, transferAmounts[i]);
            } else {
                // Send to non-EVM chains
                IDepositProcessor(depositProcessor).sendMessageBatchNonEVM{value:msg.value}(stakingTargets[i],
                    stakingAmounts[i], bridgePayloads, transferAmounts[i]);
            }
        }
    }

    function calculateStakingIncentives(
        uint256 chainId,
        bytes32 target,
        uint256 bridgingDecimals
    ) public returns (uint256 totalStakingAmount, uint256 totalReturnAmount) {
        // Check for the correct chain Id
        if (chainId == 0) {
            revert ZeroValue();
        }

        // Check for the zero address
        if (target == bytes32(0)) {
            revert ZeroAddress();
        }

        // Checkpoint the vote weighting for a target on a specific chain Id
        // If the service staking nominee does not exist, the function call reverts
        IVoteWeighting(voteWeighting).checkpointNominee(target, chainId);

        uint256 eCounter = ITokenomicsInfo(tokenomics).epochCounter();

        // Construct the nominee struct
        IVoteWeighting.Nominee memory nominee = IVoteWeighting.Nominee(target, chainId);
        // Check that the nominee exists
        bytes32 nomineeHash = keccak256(abi.encode(nominee));

        uint256 firstClaimedEpoch = mapLastClaimedStakingServiceEpochs[nomineeHash];
        // This must never happen as the nominee gets enabled when added to voteWeighting
        if (firstClaimedEpoch == 0) {
            revert();
        }

        // Shall not claim in the same epoch
        if (eCounter == firstClaimedEpoch) {
            revert();
        }

        // Get a number of epochs to claim for based on the maximum number of epochs claimed
        uint256 lastClaimedEpoch = firstClaimedEpoch + maxNumClaimingEpochs;
        if (firstClaimedEpoch + maxNumClaimingEpochs > eCounter) {
            lastClaimedEpoch = eCounter;
        }

        // Traverse all the claimed epochs
        for (uint256 j = firstClaimedEpoch; j < lastClaimedEpoch; ++j) {
            // TODO: optimize not to read several times in a row same epoch info
            // Get service staking info
            ITokenomicsInfo.StakingPoint memory stakingPoint =
                ITokenomicsInfo(tokenomics).mapEpochStakingPoints(j);

            ITokenomicsInfo.EpochPoint memory ep = ITokenomicsInfo(tokenomics).mapEpochTokenomics(j);
            uint256 endTime = ep.endTime;

            // Get the staking weight for each epoch and the total weight
            // Epoch endTime is used to get the weights info, since otherwise there is a risk of having votes
            // accounted for from the next epoch
            (uint256 stakingWeight, uint256 totalWeighSum) =
                IVoteWeighting(voteWeighting).nomineeRelativeWeight(target, chainId, endTime);

            // Adjust the inflation by the maximum amount of veOLAS voted for service staking contracts
            uint256 availableStakingAmount = stakingPoint.stakingAmount;
            if (availableStakingAmount > totalWeighSum) {
                // TODO Account for the remainder to return back to tokenomics
                availableStakingAmount = totalWeighSum;
            }

            // Compare the staking weight
            uint256 stakingAmount;
            uint256 returnAmount;
            if (stakingWeight < stakingPoint.minStakingWeight) {
                // If vote weighting staking weight is lower than the defined threshold - return the staking amount
                returnAmount = (availableStakingAmount * stakingWeight) / 1e18;
                totalReturnAmount += returnAmount;
            } else {
                // Otherwise, allocate staking amount to corresponding contracts
                stakingAmount = (availableStakingAmount * stakingWeight) / 1e18;
                if (stakingAmount > stakingPoint.maxStakingAmount) {
                    // Adjust the return amount
                    returnAmount = stakingAmount - stakingPoint.maxStakingAmount;
                    totalReturnAmount += returnAmount;
                    // Adjust the staking amount
                    stakingAmount = stakingPoint.maxStakingAmount;
                }

                // Normalize staking amount if there is a bridge decimals limiting condition
                // Note: only OLAS decimals must be considered
                if (bridgingDecimals < 18) {
                    uint256 normalizedStakingAmount = stakingAmount / (10**(18 - bridgingDecimals));
                    normalizedStakingAmount *= 10 ** (18 - bridgingDecimals);
                    // Update return amounts
                    returnAmount += stakingAmount - normalizedStakingAmount;
                    // Downsize staking amount to a specified number of bridging decimals
                    stakingAmount = normalizedStakingAmount;
                }

                totalStakingAmount += stakingAmount;
            }
        }

        // Write last claimed epoch counter to start claiming from the next time
        mapLastClaimedStakingServiceEpochs[nomineeHash] = lastClaimedEpoch;
    }

    function claimStakingIncentives(
        uint256 chainId,
        bytes32 target,
        bytes memory bridgePayload
    ) external payable {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        Pause currentPause = paused;
        if (currentPause == Pause.StakingIncentivesPaused || currentPause == Pause.AllPaused) {
            revert();
        }

        address depositProcessor = mapChainIdDepositProcessors[chainId];
        uint256 bridgingDecimals = IDepositProcessor(depositProcessor).getBridgingDecimals();

        // Staking amount to send as a deposit with, and the amount to return back to effective staking
        (uint256 stakingAmount, uint256 returnAmount) = calculateStakingIncentives(chainId, target,
            bridgingDecimals);

        // Account for possible withheld OLAS amounts
        // Note: in case of normalized staking amounts with bridging decimals, this is correctly managed
        // as normalized amounts are returned from another side
        uint256 transferAmount = stakingAmount;
        uint256 withheldAmount = mapChainIdWithheldAmounts[chainId];
        if (withheldAmount > 0) {
            // If withheld amount is enough to cover all the staking amounts, the transfer of OLAS is not needed
            if (withheldAmount >= transferAmount) {
                withheldAmount -= transferAmount;
                transferAmount = 0;
            } else {
                // Otherwise, reduce the transfer of tokens for the OLAS withheld amount
                transferAmount -= withheldAmount;
                withheldAmount = 0;
            }
            mapChainIdWithheldAmounts[chainId] = withheldAmount;
        }

        // TODO: check for balanceOf before and after the mint of OLAS
        if (transferAmount > 0) {
            // Mint tokens to the staking target dispenser
            ITreasury(treasury).withdrawToAccount(address(this), 0, transferAmount);
        }

        // TODO Check if this can be optimized in case of stakingAmount == 0 to happen earlier
        // Dispense to a service staking target
        if (stakingAmount > 0) {
            _distribute(chainId, target, stakingAmount, bridgePayload, transferAmount);
        }

        // Refund returned amount back to tokenomics inflation
        if (returnAmount > 0) {
            ITokenomicsInfo(tokenomics).refundFromStaking(returnAmount);
        }

        emit StakingIncentivesClaimed(msg.sender, stakingAmount, returnAmount);

        _locked = 1;
    }

    // TODO: Let choose epochs to claim for - set last epoch as eCounter or as last claimed.
    // TODO: Define a maximum number of targets to claim for
    // Ascending order of chain Ids
    function claimStakingIncentivesBatch(
        uint256[] memory chainIds,
        bytes32[][] memory stakingTargets,
        bytes[] memory bridgePayloads
    ) external payable {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        if (chainIds.length != stakingTargets.length || chainIds.length != bridgePayloads.length) {
            revert WrongArrayLength(chainIds.length, stakingTargets.length);
        }

        Pause currentPause = paused;
        if (currentPause == Pause.StakingIncentivesPaused || currentPause == Pause.AllPaused) {
            revert();
        }

        // TODO Check for the numEpochs(Tokenomics) * rewardsPerSecond * numServices * epochLength(Tokenomics)

        // Staking amount across all the targets to send as a deposit
        uint256 totalStakingAmount;
        // Staking amount to return back to effective staking
        uint256 totalReturnAmount;

        // Allocate the array of staking and transfer amounts
        uint256[][] memory stakingAmounts = new uint256[][](chainIds.length);
        uint256[] memory transferAmounts = new uint256[](chainIds.length);

        // TODO: derive the max number of numChains * numTargetsPerChain * numEpochs to claim => totalNumOfClaimedEpochs
        uint256 lastChainId;
        bytes32 lastTarget;
        // Traverse all chains
        for (uint256 i = 0; i < chainIds.length; ++i) {
            // Check that chain Ids are strictly in ascending non-repeatable order
            if (lastChainId >= chainIds[i]) {
                revert();
            }
            lastChainId = chainIds[i];

            // Staking targets must not be an empty array
            if (stakingTargets[i].length == 0) {
                revert ZeroValue();
            }

            address depositProcessor = mapChainIdDepositProcessors[chainIds[i]];
            uint256 bridgingDecimals = IDepositProcessor(depositProcessor).getBridgingDecimals();

            stakingAmounts[i] = new uint256[](stakingTargets[i].length);
            // Traverse all staking targets
            for (uint256 j = 0; j < stakingTargets[i].length; ++j) {
                // Enforce ascending non-repeatable order of targets
                if (uint256(lastTarget) >= uint256(stakingTargets[i][j])) {
                    revert();
                }
                lastTarget = stakingTargets[i][j];

                // Staking amount to send as a deposit with, and the amount to return back to effective staking
                (uint256 stakingAmount, uint256 returnAmount) = calculateStakingIncentives(chainIds[i],
                    stakingTargets[i][j], bridgingDecimals);

                stakingAmounts[i][j] += stakingAmount;
                transferAmounts[i] += stakingAmount;
                totalReturnAmount += returnAmount;
            }

            // Account for possible withheld OLAS amounts
            uint256 withheldAmount = mapChainIdWithheldAmounts[chainIds[i]];
            if (withheldAmount >= transferAmounts[i]) {
                withheldAmount -= transferAmounts[i];
                transferAmounts[i] = 0;
            } else {
                transferAmounts[i] -= withheldAmount;
                withheldAmount = 0;
            }
            mapChainIdWithheldAmounts[chainIds[i]] = withheldAmount;

            // Add to the total staking amount
            totalStakingAmount += transferAmounts[i];
        }

        // TODO: check for balanceOf before and after the mint of OLAS
        // TODO mint here or mint separately to each instead of a transfer
        if (totalStakingAmount > 0) {
            // Mint tokens to the staking target dispenser
            ITreasury(treasury).withdrawToAccount(address(this), 0, totalStakingAmount);
        }

        // TODO Deal with stakingAmounts[i][j] == 0 - remove them from the list
        // Dispense all the service staking targets
        _distributeBatch(chainIds, stakingTargets, stakingAmounts, bridgePayloads, transferAmounts);

        // Refund returned amount back to tokenomics inflation
        if (totalReturnAmount > 0) {
            ITokenomicsInfo(tokenomics).refundFromStaking(totalReturnAmount);
        }

        emit StakingIncentivesClaimed(msg.sender, totalStakingAmount, totalReturnAmount);

        _locked = 1;
    }

    /// @dev Sets deposit processor contracts addresses and L2 chain Ids.
    /// @notice It is the contract owner responsibility to set correct L1 deposit processor contracts
    ///         and corresponding supported L2 chain Ids.
    /// @param depositProcessors Set of deposit processor contract addresses on L1.
    /// @param chainIds Set of corresponding L2 chain Ids.
    function setDepositProcessorChainIds(
        address[] memory depositProcessors,
        uint256[] memory chainIds
    ) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for array correctness
        if (depositProcessors.length != chainIds.length) {
            revert WrongArrayLength(depositProcessors.length, chainIds.length);
        }

        // Link L1 and L2 bridge mediators, set L2 chain Ids
        for (uint256 i = 0; i < chainIds.length; ++i) {
            // Check supported chain Ids on L2
            if (chainIds[i] == 0) {
                revert ZeroValue();
            }

            // Note: depositProcessors[i] might be zero if there is a need to stop processing a specific L2 chain Id
            mapChainIdDepositProcessors[chainIds[i]] = depositProcessors[i];
        }

        emit SetDepositProcessorChainIds(depositProcessors, chainIds);
    }

    function syncWithheldAmount(uint256 chainId, uint256 amount) external {
        address depositProcessor = mapChainIdDepositProcessors[chainId];

        // Check L1 Wormhole Relayer address
        if (msg.sender != depositProcessor) {
            revert DepositProcessorOnly(msg.sender, depositProcessor);
        }

        // Add to the withheld amount
        mapChainIdWithheldAmounts[chainId] += amount;

        emit WithheldAmountSynced(chainId, amount);
    }

    /// @dev Syncs the withheld amount manually by the DAO in order to restore the data that was not delivered from L2.
    /// @notice The possible bridge failure scenario that requires to act via the DAO vote includes:
    ///         - Message from L2 to L1 fails: need to call this function.
    /// @param chainId L2 chain Id.
    /// @param amount Withheld amount that was not delivered from L2.
    function syncWithheldAmountMaintenance(uint256 chainId, uint256 amount) external {
        // Check the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // The sync must never happen for the L1 chain Id itself
        if (chainId == 1) {
            revert();
        }

        // Get bridging decimals for a specified chain Id
        address depositProcessor = mapChainIdDepositProcessors[chainId];
        uint256 bridgingDecimals = IDepositProcessor(depositProcessor).getBridgingDecimals();

        // Normalize the synced withheld amount via maintenance is correct
        if (bridgingDecimals < 18) {
            uint256 normalizedAmount = amount / (10**(18 - bridgingDecimals));
            normalizedAmount *= 10**(18 - bridgingDecimals);
            // Downsize staking amount to a specified number of bridging decimals
            amount = normalizedAmount;
        }

        // Add to the withheld amount
        mapChainIdWithheldAmounts[chainId] += amount;

        emit WithheldAmountSynced(chainId, amount);
    }

    function setPause(Pause pauseState) external {
        // Check the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        paused = pauseState;
    }
}
