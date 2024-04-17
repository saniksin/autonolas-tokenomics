const fs = require("fs");
const globalsFile = "globals.json";
const dataFromJSON = fs.readFileSync(globalsFile, "utf8");
const parsedData = JSON.parse(dataFromJSON);

module.exports = [
    parsedData.olasAddress,
    parsedData.serviceStakingFactoryAddress,
    parsedData.timelockAddress,
    parsedData.arbitrumArbSysAddress,
    parsedData.arbitrumDepositProcessorL1Address,
    parsedData.l1ChainId
];