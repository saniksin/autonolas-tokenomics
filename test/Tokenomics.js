/*global describe, beforeEach, it, context*/
const { ethers, network } = require("hardhat");
const { expect } = require("chai");

describe("Tokenomics", async () => {
    const initialMint = "1" + "0".repeat(26);
    const AddressZero = "0x" + "0".repeat(40);

    let signers;
    let deployer;
    let olasFactory;
    let tokenomicsFactory;
    let olas;
    let tokenomics;
    let serviceRegistry;
    const epochLen = 1;
    const regDepositFromServices = "1" + "0".repeat(25);
    const magicDenominator = 5192296858534816;
    const E18 = 10**18;
    const delta = 1.0 / 10**10;

    // These should not be in beforeEach.
    beforeEach(async () => {
        signers = await ethers.getSigners();
        deployer = signers[0];
        // Note: this is not a real OLAS token, just an ERC20 mock-up
        olasFactory = await ethers.getContractFactory("ERC20Token");
        tokenomicsFactory = await ethers.getContractFactory("Tokenomics");
        olas = await olasFactory.deploy();
        await olas.deployed();

        // Service registry mock
        const ServiceRegistry = await ethers.getContractFactory("MockRegistry");
        serviceRegistry = await ServiceRegistry.deploy();
        await serviceRegistry.deployed();

        const componentRegistry = await ServiceRegistry.deploy();
        const agentRegistry = await ServiceRegistry.deploy();

        // Treasury address is deployer since there are functions that require treasury only
        tokenomics = await tokenomicsFactory.deploy(olas.address, deployer.address, deployer.address, deployer.address,
            deployer.address, epochLen, componentRegistry.address, agentRegistry.address, serviceRegistry.address);

        // Mint the initial balance
        olas.mint(deployer.address, initialMint);
    });

    context("Initialization", async function () {
        it("Changing managers and owners", async function () {
            const account = signers[1];

            // Trying to change owner from a non-owner account address
            //await expect(
            //    treasury.connect(account).changeOwner(account.address)
            //).to.be.revertedWith("OwnerOnly");

            // Changing depository, dispenser and tokenomics addresses
            await tokenomics.connect(deployer).changeManagers(account.address, deployer.address, signers[2].address,
                signers[3].address);
            expect(await tokenomics.treasury()).to.equal(account.address);
            expect(await tokenomics.depository()).to.equal(deployer.address);
            expect(await tokenomics.dispenser()).to.equal(signers[2].address);
            expect(await tokenomics.ve()).to.equal(signers[3].address);

            // Changing the owner
            //await treasury.connect(deployer).changeOwner(account.address);

            // Trying to change owner from the previous owner address
            //await expect(
            //    treasury.connect(deployer).changeOwner(deployer.address)
            //).to.be.revertedWith("OwnerOnly");
        });

        it("Changing tokenomics parameters", async function () {
            await tokenomics.changeTokenomicsParameters(10, 10, 10, 10, 10, 10, 10, 10, 10, true);
        });

        it("Changing reward fractions", async function () {
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

        it("Whitelisting and de-whitelisting service owners", async function () {
            // Trying to mismatch the number of accounts and permissions
            await expect(
                tokenomics.connect(deployer).changeServiceOwnerWhiteList([AddressZero], [])
            ).to.be.revertedWithCustomError(tokenomics, "WrongArrayLength");

            // Trying to whitelist zero addresses
            await expect(
                tokenomics.connect(deployer).changeServiceOwnerWhiteList([AddressZero], [true])
            ).to.be.revertedWithCustomError(tokenomics, "ZeroAddress");

            await tokenomics.connect(deployer).changeServiceOwnerWhiteList([deployer.address], [true]);
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
            let allowed = await tokenomics.connect(deployer).callStatic.allowedNewBond(initialMint.repeat(2));
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
            await expect(
                tokenomics.connect(deployer).trackServicesETHRevenue([3], [regDepositFromServices])
            ).to.be.revertedWithCustomError(tokenomics, "ServiceDoesNotExist");
        });

        it("Send service revenues", async () => {
            await tokenomics.connect(deployer).trackServicesETHRevenue([1, 2], [regDepositFromServices, regDepositFromServices]);
        });
    });

    context("Tokenomics calculation", async function () {
        it("Checkpoint without any revenues", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            await tokenomics.connect(deployer).checkpoint();
        });

        it("Checkpoint with revenues", async () => {
            // Skip the number of blocks within the epoch
            await ethers.provider.send("evm_mine");
            // Whitelist service owners
            const accounts = await serviceRegistry.getServiceOwners();
            await tokenomics.connect(deployer).changeServiceOwnerWhiteList(accounts, [true, true]);
            // Send the revenues to services
            await tokenomics.connect(deployer).trackServicesETHRevenue([1, 2], [regDepositFromServices, regDepositFromServices]);
            // Start new epoch and calculate tokenomics parameters and rewards
            await tokenomics.connect(deployer).checkpoint();
            // Get the UCF and check the values with delta rounding error
            const lastEpoch = await tokenomics.epochCounter() - 1;
            const ucf = Number(await tokenomics.getUCF(lastEpoch) / magicDenominator) * 1.0 / E18;
            expect(Math.abs(ucf - 0.5)).to.lessThan(delta);
        });
    });

    context("Rewards", async function () {
        it("Calculate rewards", async () => {
            const accounts = await serviceRegistry.getServiceOwners();
            const result = await tokenomics.calculateStakingRewards(accounts[0], 1);
        });
    });
});
