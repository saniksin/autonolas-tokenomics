/*global process*/

const { ethers } = require("hardhat");
const { LedgerSigner } = require("@anders-t/ethers-ledger");

async function main() {
    const fs = require("fs");
    const globalsFile = "globals.json";
    const dataFromJSON = fs.readFileSync(globalsFile, "utf8");
    let parsedData = JSON.parse(dataFromJSON);
    const useLedger = parsedData.useLedger;
    const derivationPath = parsedData.derivationPath;
    const providerName = parsedData.providerName;
    let EOA;

    const provider = await ethers.providers.getDefaultProvider(providerName);
    const signers = await ethers.getSigners();

    if (useLedger) {
        EOA = new LedgerSigner(provider, derivationPath);
    } else {
        EOA = signers[0];
    }
    // EOA address
    const deployer = await EOA.getAddress();
    console.log("EOA is:", deployer);

    // Get all the necessary contract addresses
    const tokenomicsProxyAddress = parsedData.tokenomicsProxyAddress;
    const treasuryAddress = parsedData.treasuryAddress;
    const depositoryAddress = parsedData.depositoryAddress;
    const depositoryTwoAddress = parsedData.depositoryTwoAddress;

    // Get contract instances
    const tokenomics = await ethers.getContractAt("Tokenomics", tokenomicsProxyAddress);
    const treasury = await ethers.getContractAt("Treasury", treasuryAddress);
    const depository = await ethers.getContractAt("Depository", depositoryTwoAddress);

    const depositoryJSON = "abis/0.8.18/Depository.json";
    const contractFromJSON = fs.readFileSync(depositoryJSON, "utf8");
    const parsedFile = JSON.parse(contractFromJSON);
    const abi = parsedFile["abi"];
    const oldDepository = new ethers.Contract(depositoryAddress, abi, provider);

    const AddressZero = "0x" + "0".repeat(40);

    // Proposal preparation
    console.log("Proposal 4. Change depository address in tokenomics and treasury, close old products and create new ones");
    const targets = [depositoryAddress, tokenomicsProxyAddress, treasuryAddress];
    const values = [0];
    const callDatas = [
        oldDepository.interface.encodeFunctionData("close", [[2, 3, 4, 5, 6, 7, 8, 9]]),
        tokenomics.interface.encodeFunctionData("changeManagers", [AddressZero, depositoryTwoAddress, AddressZero]),
        treasury.interface.encodeFunctionData("changeManagers", [AddressZero, depositoryTwoAddress, AddressZero])
    ];

    // Additional products to create with depository contract
    const pricesLP = ["153231111055529442295", "134525552082932313062", "118937586272434705368", "106467213624036619212", "100232027299837576135"];
    const supplies = ["1000000" + "0".repeat(18), "1000000" + "0".repeat(18), "300000" + "0".repeat(18), "300000" + "0".repeat(18), "300000" + "0".repeat(18)];
    const vesting = 3600 * 24 * 7;

    for (let i = 0; i < 5; i++) {
        targets.push(depositoryTwoAddress);
        values.push(0);
        callDatas.push(depository.interface.encodeFunctionData("create", [parsedData.OLAS_ETH_PairAddress, pricesLP[i], supplies[i], vesting]));
    }

    // Proposal details
    console.log("targets:", targets);
    console.log("values:", values);
    console.log("call datas:", callDatas);
    console.log("description:", description);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
