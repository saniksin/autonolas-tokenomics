/*global describe, beforeEach, it, context*/
const { ethers, network } = require("hardhat");
const { expect } = require("chai");

describe("Tokenomics", async () => {
    const initialMint = "1" + "0".repeat(26);
    const AddressZero = "0x" + "0".repeat(40);
    const maxUint96 = "79228162514264337593543950335";

    let signers;
    let deployer;
    let olas;
    let tokenomics;
    let treasury;
    let serviceRegistry;
    let attacker;
    const epochLen = 1;
    const regDepositFromServices = "1" + "0".repeat(25);
    const twoRegDepositFromServices = "2" + "0".repeat(25);
    const E18 = 10**18;
    const delta = 1.0 / 10**10;

    // These should not be in beforeEach.
    beforeEach(async () => {
        signers = await ethers.getSigners();
        deployer = signers[0];
        // Note: this is not a real OLAS token, just an ERC20 mock-up
        const olasFactory = await ethers.getContractFactory("ERC20Token");
        const tokenomicsFactory = await ethers.getContractFactory("Tokenomics");
        olas = await olasFactory.deploy();
        await olas.deployed();

        // Service registry mock
        const ServiceRegistry = await ethers.getContractFactory("MockRegistry");
        serviceRegistry = await ServiceRegistry.deploy();
        await serviceRegistry.deployed();

        const componentRegistry = await ServiceRegistry.deploy();
        const agentRegistry = await ServiceRegistry.deploy();

        const Treasury = await ethers.getContractFactory("Treasury");
        treasury = await Treasury.deploy(olas.address, deployer.address, deployer.address, deployer.address);
        await treasury.deployed();

        const Attacker = await ethers.getContractFactory("ReentrancyAttacker");
        attacker = await Attacker.deploy(AddressZero, AddressZero);
        await attacker.deployed();

        // deployer.address is given to the contracts that are irrelevant in these tests
        tokenomics = await tokenomicsFactory.deploy(olas.address, treasury.address, deployer.address, deployer.address,
            deployer.address, epochLen, componentRegistry.address, agentRegistry.address, serviceRegistry.address);

        // Update tokenomics address for treasury
        await treasury.changeManagers(tokenomics.address, AddressZero, AddressZero, AddressZero);

        // Mint the initial balance
        await olas.mint(deployer.address, initialMint);

        // Give treasury the minter role
        await olas.changeMinter(treasury.address);
    });

    context("Initialization", async function () {
        it("Changing managers and owners", async function () {
            const account = signers[1];

            // Trying to change owner from a non-owner account address
            await expect(
                tokenomics.connect(account).changeOwner(account.address)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");

            // Trying to change owner to the zero address
            await expect(
                tokenomics.connect(deployer).changeOwner(AddressZero)
            ).to.be.revertedWithCustomError(tokenomics, "ZeroAddress");

            // Trying to change managers from a non-owner account address
            await expect(
                tokenomics.connect(account).changeManagers(AddressZero, AddressZero, AddressZero, AddressZero)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");

            // Changing depository, dispenser and tokenomics addresses
            await tokenomics.connect(deployer).changeManagers(AddressZero, account.address, deployer.address, signers[2].address);
            expect(await tokenomics.treasury()).to.equal(account.address);
            expect(await tokenomics.depository()).to.equal(deployer.address);
            expect(await tokenomics.dispenser()).to.equal(signers[2].address);

            // Changing the owner
            await tokenomics.connect(deployer).changeOwner(account.address);

            // Trying to change owner from the previous owner address
            await expect(
                tokenomics.connect(deployer).changeOwner(deployer.address)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");
        });

        it("Changing tokenomics parameters", async function () {
            // Trying to change tokenomics parameters from a non-owner account address
            await expect(
                tokenomics.connect(signers[1]).changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 10, 10, 10, true)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");

            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 10, 10, 10, true);

            // Trying to set epsilonRate bigger than 17e18
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, "171"+"0".repeat(17), 10, 10, 10, true);
            expect(await tokenomics.epsilonRate()).to.equal(10);
        });

        it("Changing reward fractions", async function () {
            // Trying to change tokenomics reward fractions from a non-owner account address
            await expect(
                tokenomics.connect(signers[1]).changeRewardFraction(50, 50, 50, 0, 0)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");

            // The sum of first 3 must not be bigger than 100
            await expect(
                tokenomics.connect(deployer).changeRewardFraction(50, 50, 50, 0, 0)
            ).to.be.revertedWithCustomError(tokenomics, "WrongAmount");

            // The sum of last 2 must not be bigger than 100
            await expect(
                tokenomics.connect(deployer).changeRewardFraction(50, 40, 10, 50, 51)
            ).to.be.revertedWithCustomError(tokenomics, "WrongAmount");

            await tokenomics.connect(deployer).changeRewardFraction(30, 40, 10, 40, 50);
        });

        it("Changing registries addresses", async function () {
            // Trying to change tokenomics parameters from a non-owner account address
            await expect(
                tokenomics.connect(signers[1]).changeRegistries(AddressZero, AddressZero, AddressZero)
            ).to.be.revertedWithCustomError(tokenomics, "OwnerOnly");

            // Leaving everything unchanged
            await tokenomics.changeRegistries(AddressZero, AddressZero, AddressZero);
            // Change registries addresses
            await tokenomics.changeRegistries(signers[1].address, signers[2].address, signers[3].address);
            expect(await tokenomics.componentRegistry()).to.equal(signers[1].address);
            expect(await tokenomics.agentRegistry()).to.equal(signers[2].address);
            expect(await tokenomics.serviceRegistry()).to.equal(signers[3].address);
        });

        it("Should fail when calling depository-owned functions by other addresses", async function () {
            await expect(
                tokenomics.connect(signers[1]).allowedNewBond(0)
            ).to.be.revertedWithCustomError(tokenomics, "ManagerOnly");

            await expect(
                tokenomics.connect(signers[1]).updateEpochBond(0)
            ).to.be.revertedWithCustomError(tokenomics, "ManagerOnly");
        });

        it("Should fail when calling treasury-owned functions by other addresses", async function () {
            await expect(
                tokenomics.connect(signers[1]).trackServicesETHRevenue([], [])
            ).to.be.revertedWithCustomError(tokenomics, "ManagerOnly");
        });

        it("Should fail when calling dispenser-owned functions by other addresses", async function () {
            await expect(
                tokenomics.connect(signers[1]).accountOwnerRewards(deployer.address)
            ).to.be.revertedWithCustomError(tokenomics, "ManagerOnly");
        });
    });

    context("Inflation schedule", async function () {
        it("Check if the mint is allowed", async () => {
            // Trying to mint more than the inflation remainder for the year
            let allowed = await tokenomics.connect(deployer).callStatic.isAllowedMint(initialMint.repeat(2));
            expect(allowed).to.equal(false);

            allowed = await tokenomics.connect(deployer).callStatic.isAllowedMint(1000);
            expect(allowed).to.equal(true);
        });

        it("Check if the new bond is allowed", async () => {
            // Trying to get a new bond amount more than the inflation remainder for the year
            let allowed = await tokenomics.connect(deployer).callStatic.allowedNewBond(maxUint96);
            expect(allowed).to.equal(false);

            allowed = await tokenomics.connect(deployer).callStatic.allowedNewBond(1000);
            expect(allowed).to.equal(true);

            // Check the same condition after 10 years
            await network.provider.send("evm_increaseTime", [3153600000]);
            await ethers.provider.send("evm_mine");
            allowed = await tokenomics.connect(deployer).callStatic.allowedNewBond(1000);
            expect(allowed).to.equal(true);
        });
    });

    context("Track revenue of services", async function () {
        it("Should fail when the service does not exist", async () => {
            // Only treasury can access the function, so let's change it for deployer here
            await tokenomics.changeManagers(AddressZero, deployer.address, AddressZero, AddressZero);

            await expect(
                tokenomics.connect(deployer).trackServicesETHRevenue([3], [regDepositFromServices])
            ).to.be.revertedWithCustomError(tokenomics, "ServiceDoesNotExist");
        });

        it("Send service revenues twice for protocol-owned services and donation", async () => {
            // Only treasury can access the function, so let's change it for deployer here
            await tokenomics.changeManagers(AddressZero, deployer.address, AddressZero, AddressZero);

            await tokenomics.connect(deployer).trackServicesETHRevenue([1, 2], [regDepositFromServices, regDepositFromServices]);
            await tokenomics.connect(deployer).trackServicesETHRevenue([1], [regDepositFromServices]);
        });
    });

    context("Tokenomics calculation", async function () {
        it("Checkpoint without any revenues", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            await tokenomics.connect(deployer).checkpoint();

            // Set the auto-control of effective bond calculation
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 10, 1, 10, true);
            await ethers.provider.send("evm_mine");
            await tokenomics.connect(deployer).checkpoint();

            // Try to run checkpoint while the epoch length is not yet reached
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 10, 10, 10, true);
            await tokenomics.connect(deployer).checkpoint();
        });

        it("Checkpoint with revenues", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            // Send the revenues to services
            await treasury.connect(deployer).depositETHFromServices([1, 2], [regDepositFromServices,
                regDepositFromServices], {value: twoRegDepositFromServices});
            // Start new epoch and calculate tokenomics parameters and rewards
            await tokenomics.connect(deployer).checkpoint();

            // Get the UCF and check the values with delta rounding error
            const lastEpoch = await tokenomics.epochCounter() - 1;
            const ucf = Number(await tokenomics.getUCF(lastEpoch)) * 1.0 / E18;
            expect(Math.abs(ucf - 0.5)).to.lessThan(delta);
            // Get the epochs data
            // Get the very first point
            await tokenomics.getPoint(1);
            // Get the last point
            await tokenomics.getLastPoint();

            // Get IDF of the last epoch
            const idf = Number(await tokenomics.getIDF(lastEpoch)) / E18;
            expect(idf).to.greaterThan(1);
            
            // Get last IDF that must match the idf of the last epoch
            const lastIDF = Number(await tokenomics.getLastIDF()) / E18;
            expect(idf).to.equal(lastIDF);

            // Get IDF of the zero (arbitrary) epoch
            const defaultEpsRate = Number(await tokenomics.epsilonRate()) + E18;
            const zeroDF = Number(await tokenomics.getIDF(0));
            expect(zeroDF).to.equal(defaultEpsRate);

            // Get UCF of the zero (arbitrary) epoch
            const zeroUCF = Number(await tokenomics.getUCF(0));
            expect(zeroUCF).to.equal(0);

        });

        it("Get IDF based on the epsilonRate", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            const accounts = await serviceRegistry.getUnitOwners();
            // Send the revenues to services
            await treasury.connect(deployer).depositETHFromServices(accounts, [regDepositFromServices,
                regDepositFromServices], {value: twoRegDepositFromServices});
            // Start new epoch and calculate tokenomics parameters and rewards
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 0, 10, 10, true);
            await tokenomics.connect(deployer).checkpoint();

            // Get IDF
            const lastEpoch = await tokenomics.epochCounter() - 1;
            const idf = Number(await tokenomics.getIDF(lastEpoch)) / E18;
            expect(idf).to.greaterThan(Number(await tokenomics.epsilonRate()) / E18);

            // Change max bond twice such that adjustment of max bond is tested
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 1, 10, 10, true);
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 0, 10, 10, true);
        });
    });

    context("Rewards", async function () {
        it("Calculate rewards", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            const accounts = await serviceRegistry.getUnitOwners();
            // Send the revenues to services
            await treasury.connect(deployer).depositETHFromServices(accounts, [regDepositFromServices,
                regDepositFromServices], {value: twoRegDepositFromServices});

            // Try to fail the reward allocation
            await tokenomics.changeManagers(AddressZero, attacker.address, AddressZero, AddressZero);
            await expect(
                tokenomics.connect(deployer).checkpoint()
            ).to.be.revertedWithCustomError(tokenomics, "RewardsAllocationFailed");

            // Start new epoch and calculate tokenomics parameters and rewards
            await tokenomics.changeManagers(AddressZero, treasury.address, AddressZero, AddressZero);
            await tokenomics.connect(deployer).checkpoint();
            // Get the rewards data
            const pe = await tokenomics.getLastPoint();
            const accountRewards = Number(pe.stakerRewards) + Number(pe.ucfc.unitRewards) + Number(pe.ucfa.unitRewards);
            const accountTopUps = Number(pe.ownerTopUps) + Number(pe.stakerTopUps);
            expect(accountRewards).to.greaterThan(0);
            expect(accountTopUps).to.greaterThan(0);

            // Calculate staking rewards
            const result = await tokenomics.calculateStakingRewards(accounts[0], 1);
            // Get owner rewards
            await tokenomics.getOwnerRewards(accounts[0]);
            expect(result.endEpochNumber).to.equal(2);

            // Get the top-up number per epoch
            const topUp = await tokenomics.getTopUpPerEpoch();
            expect(topUp).to.greaterThan(0);
        });
    });
});
