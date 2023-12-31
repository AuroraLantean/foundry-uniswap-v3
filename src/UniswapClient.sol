// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;
pragma abicoder v2;
/*deployed at Goerli 0x72a452eC001265AD711C60fe27F71e2Cd0ADCC39
 */

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
//https://docs.uniswap.org/contracts/v3/reference/core/UniswapV3Factory
//factory includes IFactory, PoolDeployer, Pool
//Pool includes LowGasSafeMath, IUniswapV3FlashCallback, IUniswapV3MintCallback, IUniswapV3SwapCallback

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";

//https://docs.uniswap.org/contracts/v3/guides/swaps/multihop-swaps
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol"; //getPoolKey, computeAddress
import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol"; // verifyCallback
import "@uniswap/v3-periphery/contracts/base/LiquidityManagement.sol";

//import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "src/TransferPayHelper.sol";
import "src/LowGasSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

//According to https://docs.uniswap.org/contracts/v3/guides/providing-liquidity/setting-up
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "forge-std/console.sol";

contract UniswapClient is IUniswapV3FlashCallback, PeripheryPaymentsB, IERC721Receiver {
    using LowGasSafeMathB for uint256;
    using LowGasSafeMathB for int256;

    address payable owner;
    ISwapRouter public immutable router;
    //IUniswapV3Factory public immutable uniswapV3Factory;
    //IQuoter public immutable quoter;
    INonfungiblePositionManager public immutable nfPosMgr;

    //import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = -MIN_TICK;
    int24 constant TICK_SPACING = 60;
    address constant zero = address(0);

    struct DepositNFT {
        address sender;
        uint128 liquidity;
        address token0;
        address token1;
    }

    uint256 public lastNftDepositId;
    mapping(uint256 => DepositNFT) public nftDeposits;

    // msg.sender must approve this contract
    constructor(address _factory, address _WETH9, address _routerAddr, address _nfPosMgrAddr)
        PeripheryPaymentsB(_factory, _WETH9)
    {
        require(
            _factory != zero && _WETH9 != zero && _routerAddr != zero && _nfPosMgrAddr != zero,
            "input addresses must not be zero"
        );
        owner = payable(msg.sender);
        router = ISwapRouter(_routerAddr);
        nfPosMgr = INonfungiblePositionManager(_nfPosMgrAddr);
        //uniswapV3Factory = IUniswapV3Factory(_factory);
        //quoter = IQuoter(_quoterAddr);
    }

    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _markDeposit(operator, tokenId);
        return this.onERC721Received.selector;
    }

    // https://docs.uniswap.org/contracts/v3/guides/providing-liquidity/setting-up
    function _markDeposit(address _sender, uint256 tokenId) internal {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) = nfPosMgr.positions(tokenId);
        // set the sender and data for position
        // operator is msg.sender
        nftDeposits[tokenId] = DepositNFT({sender: _sender, liquidity: liquidity, token0: token0, token1: token1});
        lastNftDepositId = tokenId;
    }

    event OOOOOO(uint256 a, uint256 b, uint256 c);
    // tokenId The id of the newly minted ERC721, liquidity The amount of liquidity for the position, amount0 The amount of token0, amount1 The amount of token1

    function mintNewPosition(address token0, address token1, uint24 poolFee, uint256 amt0ToAdd, uint256 amt1ToAdd)
        external
        returns (uint256 tokenId, uint128 liquidityDelta, uint256 amount0, uint256 amount1)
    {
        console.log("mintNewPosition");
        // Transfer token0 and token1 from caller to here
        TransferHelperB.safeTransferFrom(token0, msg.sender, address(this), amt0ToAdd);
        console.log("mintNewPosition_1");
        TransferHelperB.safeTransferFrom(token1, msg.sender, address(this), amt1ToAdd);
        console.log("mintNewPosition_2");

        // Approve the position manager
        TransferHelperB.safeApprove(token0, address(nfPosMgr), amt0ToAdd);
        console.log("mintNewPosition_3");
        TransferHelperB.safeApprove(token1, address(nfPosMgr), amt1ToAdd);
        console.log("mintNewPosition_4");

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            tickLower: (MIN_TICK / TICK_SPACING) * TICK_SPACING, //TickMath.MIN_TICK,
            tickUpper: (MAX_TICK / TICK_SPACING) * TICK_SPACING, //TickMath.MAX_TICK,
            amount0Desired: amt0ToAdd,
            amount1Desired: amt1ToAdd,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Note that the pool defined by token0/token1 and fee tier 0.3% must already be created and initialized in order to mint
        (tokenId, liquidityDelta, amount0, amount1) = nfPosMgr.mint(params);
        console.log("mintNewPosition_6");

        _markDeposit(msg.sender, tokenId);
        console.log("mintNewPosition_7");

        // Remove allowance and refund in both assets.
        if (amount0 < amt0ToAdd) {
            TransferHelperB.safeApprove(token0, address(nfPosMgr), 0);
            console.log("mintNewPosition_8");
            uint256 refund0 = amt0ToAdd - amount0;
            TransferHelperB.safeTransfer(token0, msg.sender, refund0);
        }
        console.log("mintNewPosition_9");

        if (amount1 < amt1ToAdd) {
            TransferHelperB.safeApprove(token1, address(nfPosMgr), 0);
            console.log("mintNewPosition_10");
            uint256 refund1 = amt1ToAdd - amount1;
            TransferHelperB.safeTransfer(token1, msg.sender, refund1);
        }
        console.log("mintNewPosition_end");
    }

    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function collectAllFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        //The contract must hold the erc721 token before it can collect fees
        // Caller must own the ERC721 position
        // Call to safeTransfer will trigger `onERC721Received` which must return the selector else transfer will fail
        console.log("collectAllFees1", address(this), msg.sender);
        //nfPosMgr.approve(msg.sender, tokenId);
        //nfPosMgr.safeTransferFrom(msg.sender, address(this), tokenId);

        // set amount0Max and amount1Max to uint256.max to collect all fees. alternatively can set recipient to msg.sender and avoid another transaction in `sendToOwner`
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        console.log("collectAllFees3");
        (amount0, amount1) = nfPosMgr.collect(params);
        console.log("collectAllFees4");
        _sendToSender(tokenId, amount0, amount1);
    }

    function _sendToSender(uint256 tokenId, uint256 amount0, uint256 amount1) internal {
        address _sender = nftDeposits[tokenId].sender;
        address token0 = nftDeposits[tokenId].token0;
        address token1 = nftDeposits[tokenId].token1;
        TransferHelperB.safeTransfer(token0, _sender, amount0);
        TransferHelperB.safeTransfer(token1, _sender, amount1);
    }

    function decreaseLiquidityCurrentRange(uint256 tokenId, uint128 percentage)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(msg.sender == nftDeposits[tokenId].sender, "Not the sender");
        require(percentage <= 100, "percentage");
        uint128 liquidity = nftDeposits[tokenId].liquidity;
        uint128 aLiquidity = liquidity * percentage / 100;

        // amount0Min and amount1Min are price slippage checks
        // if the amount received after burning is not greater than these minimums, transaction will fail
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: aLiquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });

        (amount0, amount1) = nfPosMgr.decreaseLiquidity(params);
        _sendToSender(tokenId, amount0, amount1);
    }

    //assumes the contract already has custody of the NFT.
    //We cannot change the boundaries of a given liquidity position using the Uniswap v3 protocol; increaseLiquidity can only increase the liquidity of a position.
    //amount0Min and amount1Min should be adjusted to create slippage protections.
    function increaseLiquidityCurrentRange(uint256 amount0ToAdd, uint256 amount1ToAdd, uint256 tokenId)
        external
        returns (uint128 liquidity_, uint256 amount0, uint256 amount1)
    {
        console.log("increaseLiquidity");
        pay(nftDeposits[tokenId].token0, msg.sender, address(this), amount0ToAdd);
        pay(nftDeposits[tokenId].token1, msg.sender, address(this), amount1ToAdd);
        console.log("increaseLiquidity1");
        TransferHelperB.safeApprove(nftDeposits[tokenId].token0, address(router), amount0ToAdd);
        TransferHelperB.safeApprove(nftDeposits[tokenId].token1, address(router), amount1ToAdd);
        console.log("increaseLiquidity2");
        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: amount0ToAdd,
            amount1Desired: amount1ToAdd,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        console.log("increaseLiquidity3");
        (liquidity_, amount0, amount1) = nfPosMgr.increaseLiquidity(params);
    }

    /// @notice Transfers the NFT to the sender
    /// @param tokenId The id of the erc721
    function retrieveNFT(uint256 tokenId) external {
        // must be the sender of the NFT
        require(msg.sender == nftDeposits[tokenId].sender, "Not the sender");
        // transfer ownership to original sender
        nfPosMgr.safeTransferFrom(address(this), msg.sender, tokenId);
        //remove information related to tokenId
        delete nftDeposits[tokenId];
    }
    //------------------==
    /// https://info.uniswap.org/#/

    //see IUniswapV3MintCallback.sol
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        //TODO must pay the pool tokens owed for the minted liquidity. The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    }

    //see IUniswapV3SwapCallback.sol
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        //TODO must pay the pool tokens owed for the swap.
        /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
        /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    }

    struct FlashParams {
        address token0;
        address token1;
        uint24 poolFee; //pool loan fee
        uint256 amount0;
        uint256 amount1;
        uint24 fee10; //fee for token1 -> token0
        uint24 fee01; //fee for token0 -> token1
    }

    //https://solidity-by-example.org/defi/uniswap-v3-flash/
    function flashPool(FlashParams memory params) external {
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.poolFee});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // require(allowanceToken(params.token0) >= params.amount0, "not enough amount0");
        // require(allowanceToken(params.token1) >= params.amount1, "not enough amount1");

        pool.flash(
            address(this),
            params.amount0,
            params.amount1,
            abi.encode(
                FlashCallbackData({
                    amount0: params.amount0,
                    amount1: params.amount1,
                    payer: msg.sender,
                    poolKey: poolKey,
                    fee10: params.fee10,
                    fee01: params.fee01
                })
            )
        );
    }

    struct FlashCallbackData {
        uint256 amount0;
        uint256 amount1;
        address payer;
        PoolAddress.PoolKey poolKey;
        uint24 fee10;
        uint24 fee01;
    }
    //required by IUniswapV3FlashCallback

    //https://solidity-by-example.org/defi/uniswap-v3-flash-swap/
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        //here we should have received tokens from the pool
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey); //require(msg.sender == address(pool), "Only Callback");
        address tok0 = decoded.poolKey.token0;
        address tok1 = decoded.poolKey.token1;

        //router approves this client to use the fund
        TransferHelperB.safeApprove(tok0, address(router), decoded.amount0);
        TransferHelperB.safeApprove(tok1, address(router), decoded.amount1);

        uint256 amount1Owed = LowGasSafeMathB.add(decoded.amount1, fee1); //minimum amount1
        uint256 amount0Owed = LowGasSafeMathB.add(decoded.amount0, fee0); //minimum amount0

        uint256 amountOut0 = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tok1,
                tokenOut: tok0,
                fee: decoded.fee10,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: decoded.amount1,
                amountOutMinimum: amount0Owed,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 amountOut1 = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tok0,
                tokenOut: tok1,
                fee: decoded.fee01,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: decoded.amount0,
                amountOutMinimum: amount1Owed,
                sqrtPriceLimitX96: 0
            })
        );

        //TransferHelperB.safeApprove(tok0, address(this), amount0Owed);
        //TransferHelperB.safeApprove(tok1, address(this), amount1Owed);

        if (amount0Owed > 0) pay(tok0, address(this), msg.sender, amount0Owed);
        if (amount1Owed > 0) pay(tok1, address(this), msg.sender, amount1Owed);

        if (amountOut0 > amount0Owed) {
            uint256 profit0 = LowGasSafeMathB.sub(amountOut0, amount0Owed);
            //router to approve this client to grab the profit
            TransferHelperB.safeApprove(tok0, address(this), profit0);
            pay(tok0, address(this), decoded.payer, profit0);
        }
        if (amountOut1 > amount1Owed) {
            uint256 profit1 = LowGasSafeMathB.sub(amountOut1, amount1Owed);
            TransferHelperB.safeApprove(tok0, address(this), profit1);
            pay(tok1, address(this), decoded.payer, profit1);
        }
    }

    function swapExactInputMultiHop(bytes calldata path, address tokenIn, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(router), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0
        });
        amountOut = router.exactInput(params);
    }

    //----------------------==
    function approveToken(address tokenAddr, address spender, uint256 _amount) external onlyOwner returns (bool) {
        if (spender == address(0)) spender = address(router);
        return IERC20(tokenAddr).approve(spender, _amount);
    }

    function allowanceToken(address tokenAddr) public view returns (uint256) {
        return IERC20(tokenAddr).allowance(address(this), address(router));
    }

    function getTokenBalc(address _tokenAddr) external view returns (uint256) {
        return IERC20(_tokenAddr).balanceOf(address(this));
    }

    function withdrawToken(address _tokenAddr) external onlyOwner {
        IERC20 tok = IERC20(_tokenAddr);
        tok.transfer(msg.sender, tok.balanceOf(address(this)));
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    //receive() external payable {} //already included in PeripheryPayments.sol
}

contract DeployBytecode {
    event Deploy(address);

    receive() external payable {}

    function deployBytecode(bytes memory _code) external payable returns (address addr) {
        assembly {
            // make(v, p, n)
            // v = amount of ETH to send
            // p = pointer in memory to start of code. We need to tell Solidity where the start of the code is. The first 32 bytes encodes the lenghth of the code. So we need to skip the first 32 bytes(32 in decimal is 0x20 in hexidecimal)
            // n = size of code, which is stored in the first 32 bytes of _code... use mload(_code)
            addr := create(callvalue(), add(_code, 0x20), mload(_code))
        }
        // return address 0 on error
        require(addr != address(0), "deploy failed");

        emit Deploy(addr);
    }

    function execute(address _target, bytes memory _data) external payable {
        (bool success,) = _target.call{value: msg.value}(_data);
        require(success, "failed");
    }
}
