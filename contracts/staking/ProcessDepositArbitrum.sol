// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface L1ERC20Gateway {
    /**
     * @notice Deposit ERC20 token from Ethereum into Arbitrum. If L2 side hasn't been deployed yet, includes name/symbol/decimals data for initial L2 deploy. Initiate by GatewayRouter.
     * @dev L2 address alias will not be applied to the following types of addresses on L1:
     *      - an externally-owned account
     *      - a contract in construction
     *      - an address where a contract will be created
     *      - an address where a contract lived, but was destroyed
     * @param _l1Token L1 address of ERC20
     * @param _refundTo Account, or its L2 alias if it have code in L1, to be credited with excess gas refund in L2
     * @param _to Account to be credited with the tokens in the L2 (can be the user's L2 account or a contract), not subject to L2 aliasing
                  This account, or its L2 alias if it have code in L1, will also be able to cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param _gasPriceBid Gas price for L2 execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    //  * @param maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
    function outboundTransferCustomRefund(
        address _l1Token,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory res);
}

contract ProcessDepositArbitrum {
    address public immutable olas;
    address public immutable l1ERC20Gateway;

    constructor(address _olas, address _l1ERC20Gateway) {
        if (_olas == address(0) || _l1ERC20Gateway == address(0)) {
            revert();
        }
        olas = _olas;
        l1ERC20Gateway = _l1ERC20Gateway;
    }

    // TODO: We need to send to the target dispenser and supply with the staking contract target message?
    function deposit(address target, uint256 amount, bytes memory payload) {
        // Transfer OLAS tokens
        IToken(olas).transferFrom(dispenser, address(this), amount);

        // Decode the staking contract supplemental payload required for bridging tokens
        (address refundTo, uint256 maxGas, uint256 gasPriceBid, uint256 maxSubmissionCost) = abi.decode(payload,
            (address, uint256, uint256, uint256));

        // Construct the data for L1ERC20Gateway consisting of 2 pieces:
        // uint256 maxSubmissionCost: Max gas deducted from user's L2 balance to cover base submission fee
        // bytes extraData: “0x”
        bytes memory data = abi.encode(maxSubmissionCost, bytes(0));

        // Approve OLAS for the gateway
        IToken(olas).approve(l1ERC20Gateway, amount);

        // Transfer OLAS to the staking contract across the bridge
        L1ERC20Gateway(l1ERC20Gateway).outboundTransferCustomRefund(olas, refundTo, target, stakingAmount, maxGas,
            gasPriceBid, data);
    }
}