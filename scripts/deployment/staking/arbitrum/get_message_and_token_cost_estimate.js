/*global process*/

const { ethers } = require("hardhat");
const { L1ToL2MessageGasEstimator } = require("@arbitrum/sdk/dist/lib/message/L1ToL2MessageGasEstimator");
const { EthBridger, getL2Network } = require("@arbitrum/sdk");
const { getBaseFee } = require("@arbitrum/sdk/dist/lib/utils/lib");

const main = async () => {
    // Setting up providers and wallets
    const ALCHEMY_API_KEY_SEPOLIA = process.env.ALCHEMY_API_KEY_SEPOLIA;
    const sepoliaURL = "https://eth-sepolia.g.alchemy.com/v2/" + ALCHEMY_API_KEY_SEPOLIA;
    const sepoliaProvider = new ethers.providers.JsonRpcProvider(sepoliaURL);
    await sepoliaProvider.getBlockNumber().then((result) => {
        console.log("Current block number sepolia: " + result);
    });

    const arbitrumSepoliaURL = "https://sepolia-rollup.arbitrum.io/rpc";
    const arbitrumSepoliaProvider = new ethers.providers.JsonRpcProvider(arbitrumSepoliaURL);
    await arbitrumSepoliaProvider.getBlockNumber().then((result) => {
        console.log("Current block number arbitrum sepolia: " + result);
    });

    // Get the EOA
    const account = ethers.utils.HDNode.fromMnemonic(process.env.TESTNET_MNEMONIC).derivePath("m/44'/60'/0'/0/0");
    const EOAsepolia = new ethers.Wallet(account, sepoliaProvider);
    const EOAarbitrumSepolia = new ethers.Wallet(account, arbitrumSepoliaProvider);
    console.log("EOA", EOAsepolia.address);
    if (EOAarbitrumSepolia.address == EOAsepolia.address) {
        console.log("Correct wallet setup");
    }

    const l1DepositProcessorAddress = "0xE47F503C8C602D9B70E01627915dDAa4ee05531b";
    const l2TargetDispenserAddress = "0x11EAdb54abB2476ddA705D80048516714274b07d";
    //const erc20Token = (await ethers.getContractAt("ERC20Token", tokenAddress)).connect(EOAarbitrumSepolia);
    //console.log(erc20Token.address);

    // Use l2Network to create an Arbitrum SDK EthBridger instance
    // We'll use EthBridger to retrieve the Inbox address
    const l2Network = await getL2Network(arbitrumSepoliaProvider);
    const ethBridger = new EthBridger(l2Network);

    // Query the required gas params using the estimateAll method in Arbitrum SDK
    const l1ToL2MessageGasEstimate = new L1ToL2MessageGasEstimator(arbitrumSepoliaProvider);
    //console.log(l1ToL2MessageGasEstimate);

    // To be able to estimate the gas related params to our L1-L2 message, we need to know how many bytes of calldata out
    // retryable ticket will require
    const targetInstance = "0x2796c0470516C588383e50639dF12414d2CA4D14";
    const defaultAmount = 100;
    const stakingTargets = [targetInstance];
    const stakingAmounts = new Array(stakingTargets.length).fill(defaultAmount);
    let payloadData = ethers.utils.defaultAbiCoder.encode(["address[]","uint256[]"], [stakingTargets, stakingAmounts]);
    let receiverABI = ["function receiveMessage(bytes memory data)"];
    let iReceiver = new ethers.utils.Interface(receiverABI);
    const messageCalldata = iReceiver.encodeFunctionData("receiveMessage", [payloadData]);

    // Users can override the estimated gas params when sending an L1-L2 message
    // Note that this is totally optional
    // Here we include and example for how to provide these overriding values
    const RetryablesGasOverrides = {
        gasLimit: {
            base: undefined, // when undefined, the value will be estimated from rpc
            min: ethers.BigNumber.from(10000), // set a minimum gas limit, using 10000 as an example
            percentIncrease: ethers.BigNumber.from(30), // how much to increase the base for buffer
        },
        maxSubmissionFee: {
            base: undefined,
            percentIncrease: ethers.BigNumber.from(30),
        },
        maxFeePerGas: {
            base: undefined,
            percentIncrease: ethers.BigNumber.from(30),
        },
    };

    const l1BaseFee = await getBaseFee(sepoliaProvider);

    // Estimate all costs for the message sending
    // The estimateAll method gives us the following values for sending an L1->L2 message
    // (1) maxSubmissionCost: The maximum cost to be paid for submitting the transaction
    // (2) gasLimit: The L2 gas limit
    // (3) deposit: The total amount to deposit on L1 to cover L2 gas and L2 call value
    const L1ToL2MessageGasParams = await l1ToL2MessageGasEstimate.estimateAll(
        {
            from: l1DepositProcessorAddress,
            to: l2TargetDispenserAddress,
            l2CallValue: 0,
            excessFeeRefundAddress: EOAarbitrumSepolia.address,
            callValueRefundAddress: EOAarbitrumSepolia.address,
            data: messageCalldata,
        },
        l1BaseFee,
        sepoliaProvider,
        RetryablesGasOverrides //if provided, it will override the estimated values. Note that providing "RetryablesGasOverrides" is totally optional.
    );
    const gasPriceBid = L1ToL2MessageGasParams.maxFeePerGas;
    const gasLimitMessage = L1ToL2MessageGasParams.gasLimit;
    const maxSubmissionCostMessage = L1ToL2MessageGasParams.maxSubmissionCost;
    console.log("gasPriceBid:", gasPriceBid.toString());
    console.log("gasLimitMessage:", gasLimitMessage.toString());
    console.log("maxSubmissionCostMessage:", maxSubmissionCostMessage.toString());

    // Token-related calculations
    // Token relayer contracts
    // const l1ERC20GatewayAddress = ethBridger.l2Network.tokenBridge.l1ERC20GatewayAddress;
    // const l2ERC20GatewayAddress = ethBridger.l2Network.tokenBridge.l2ERC20GatewayAddress;
    // Payload data similar to what is received on the L2 side
    payloadData = "0x000000000000000000000000000000000000000000000000000005f775d5788000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000";
    receiverABI = ["function finalizeInboundTransfer(address _token, address _from, address _to, uint256 _amount, bytes memory _data)"];
    iReceiver = new ethers.utils.Interface(receiverABI);

    // Use targetInstance as a token since it doesn't matter - we just need an address there,
    // since the cost is computed based on the transferred data
    const tokenCalldata = iReceiver.encodeFunctionData("finalizeInboundTransfer", [targetInstance,
        EOAarbitrumSepolia.address, EOAarbitrumSepolia.address, defaultAmount, payloadData]);

    // Estimate maxSubmissionCost for the token sending
    const maxSubmissionCostToken = await l1ToL2MessageGasEstimate.estimateSubmissionFee(sepoliaProvider, l1BaseFee,
        ethers.utils.hexDataLength(tokenCalldata));
    console.log("maxSubmissionCostToken:", maxSubmissionCostToken.toString());

    const tokenGasLimit = ethers.BigNumber.from("300000");
    const tokenGasCost = gasPriceBid.mul(tokenGasLimit);
    const totalCost = L1ToL2MessageGasParams.deposit.add(maxSubmissionCostToken).add(tokenGasCost);
    console.log("Total cost:", totalCost.toString());

    const finalPayload = ethers.utils.defaultAbiCoder.encode(["address", "uint256", "uint256", "uint256", "uint256"],
        [EOAarbitrumSepolia.address, gasPriceBid, maxSubmissionCostToken, gasLimitMessage, maxSubmissionCostMessage]);
    console.log("ArbitrumDepositProcessorL1 payload:", finalPayload);


    // TESTING OF SENDING TOKEN AND MESSAGE
    const fs = require("fs");
    const dispenserAddress = "0x210af5b2FD68b3cdB94843C8e3462Daa52cCfe8F";
    const dispenserJSON = "artifacts/contracts/test/MockServiceStakingDispenser.sol/MockServiceStakingDispenser.json";
    let contractFromJSON = fs.readFileSync(dispenserJSON, "utf8");
    parsedFile = JSON.parse(contractFromJSON);
    const dispenserABI = parsedFile["abi"];
    const dispenser = new ethers.Contract(dispenserAddress, dispenserABI, sepoliaProvider);

    const olasAddress = "0x2AeD71638128A3811F5e5971a397fFe6A8587caa";
    const olasJSON = "artifacts/contracts/test/ERC20TokenOwnerless.sol/ERC20TokenOwnerless.json";
    contractFromJSON = fs.readFileSync(olasJSON, "utf8");
    parsedFile = JSON.parse(contractFromJSON);
    const olasABI = parsedFile["abi"];
    const olas = new ethers.Contract(olasAddress, olasABI, arbitrumSepoliaProvider);
    const totalSupply = await olas.totalSupply();
    console.log("totalSupply on L2:", totalSupply);
    let balance = await olas.balanceOf(l2TargetDispenserAddress);
    console.log("balance of L2 target dispenser:", balance);
    balance = await olas.balanceOf(targetInstance);
    console.log("balance of L2 proxy:", balance);
    return;

    const transferAmount = defaultAmount;
    const gasLimit = 3000000;
    const tx = await dispenser.connect(EOAsepolia).mintAndSend(l1DepositProcessorAddress, targetInstance, defaultAmount,
        finalPayload, transferAmount, { value: totalCost, gasLimit });
    console.log("TX hash", tx.hash);
    await tx.wait();

    // tx back to L1: https://sepolia.arbiscan.io/tx/0xde0193236bce2ae7ecedff473853b994ed3f678c8823db70190593d8e757b548

    // TODO This must be called as IBridge.executeTransaction() after the transaction challenge period has passed
    // Source: https://github.com/OffchainLabs/nitro-contracts/blob/67127e2c2fd0943d9d87a05915d77b1f220906aa/src/bridge/Outbox.sol#L123
    // Docs: https://docs.arbitrum.io/arbos/l2-to-l1-messaging
    /**
     * @notice Executes a messages in an Outbox entry.
     * @dev Reverts if dispute period hasn't expired, since the outbox entry
     *      is only created once the rollup confirms the respective assertion.
     * @dev it is not possible to execute any L2-to-L1 transaction which contains data
     *      to a contract address without any code (as enforced by the Bridge contract).
     * @param proof Merkle proof of message inclusion in send root
     * @param index Merkle path to message
     * @param l2Sender sender if original message (i.e., caller of ArbSys.sendTxToL1)
     * @param to destination address for L1 contract call
     * @param l2Block l2 block number at which sendTxToL1 call was made
     * @param l1Block l1 block number at which sendTxToL1 call was made
     * @param l2Timestamp l2 Timestamp at which sendTxToL1 call was made
     * @param value wei in L1 message
     * @param data abi-encoded L1 message data
     */
//    function executeTransaction(
//        bytes32[] calldata proof,
//        uint256 index,
//        address l2Sender,
//        address to,
//        uint256 l2Block,
//        uint256 l1Block,
//        uint256 l2Timestamp,
//        uint256 value,
//        bytes calldata data
//    ) external;
};

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
