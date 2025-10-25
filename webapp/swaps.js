// swaps.js

const FACTORY_ADDRESS = '0x263a00623e00e135ec1810280d491c0fd4e5b8dd';
const SWAPPER_ADDRESS = '0xYourSwapperV3AddressHere'; // replace
const FEE_TIER = 10000; // 1%

const SQRT_PRICE_LIMIT_UP = 0x1000276FFn;
const SQRT_PRICE_LIMIT_DOWN = 0x00fffd8963efd1fc6a506488495d951d5263988d00n;

const poolFactoryAbi = [
	'function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool)'
];

const swapperAbi = [
	'function swapV3ExactIn(address pool, bool zeroForOne, uint256 amountIn, uint128 minimum) external',
	'function swapV3ExactOut(address pool, bool zeroForOne, uint256 amountOut, uint128 maximum) external'
];

const poolAbi = [
	'function slot0() external view returns (uint160 sqrtPriceX96,int24 tick,uint16 observationIndex,uint16 observationCardinality,uint16 observationCardinalityNext,uint8 feeProtocol,bool unlocked)',
	'function computeExpectedTokensOut(address inputToken,uint256 maxTokensIn,uint160 sqrtPriceX96,uint160 sqrtPriceLimitX96) external view returns (uint256 tokensIn,uint256 tokensOut,uint160 newSqrtPriceX96)',
	'function computeExpectedTokensIn(address inputToken,uint256 maxTokensOut,uint160 sqrtPriceX96,uint160 sqrtPriceLimitX96) external view returns (uint256 tokensIn,uint256 tokensOut,uint160 newSqrtPriceX96)'
];

const erc20Abi = [
	'function allowance(address owner, address spender) view returns (uint256)',
	'function approve(address spender, uint256 value) returns (bool)'
];

/**
 * Ensures SwapperV3 can spend user's tokens.
 */
async function ensureApproval(signer, token, amount) {
	const contract = new ethers.Contract(token, erc20Abi, signer);
	const owner = await signer.getAddress();
	const allowance = await contract.allowance(owner, SWAPPER_ADDRESS);
	if (allowance < amount) {
		const tx = await contract.approve(SWAPPER_ADDRESS, amount);
		await tx.wait();
	}
}

/**
 * Estimates output or input for swap with slippage margin.
 */
async function estimateSwap(signer, tokenIn, tokenOut, amount, exactIn = true) {
	console.log(signer, tokenIn, tokenOut, amount, exactIn);
	const factory = new ethers.Contract(FACTORY_ADDRESS, poolFactoryAbi, signer.provider);
	const poolAddress = await factory.getPool(tokenIn, tokenOut, FEE_TIER);
	console.log("Pool: " + poolAddress);
	if (poolAddress === ethers.ZeroAddress) throw new Error('Pool not found');

	const pool = new ethers.Contract(poolAddress, poolAbi, signer.provider);
	const { sqrtPriceX96 } = await pool.slot0();
	console.log("sqrtPriceX96: " + sqrtPriceX96);

	const zeroForOne = tokenIn.toLowerCase() < tokenOut.toLowerCase();
	const sqrtLimit = zeroForOne ? SQRT_PRICE_LIMIT_DOWN : SQRT_PRICE_LIMIT_UP;

	let tokensIn, tokensOut;
	if (exactIn) {
		console.log(tokenIn, amount, sqrtPriceX96, sqrtLimit);
		({ tokensIn, tokensOut } = await pool.computeExpectedTokensOut(
			tokenIn,
			amount,
			sqrtPriceX96,
			sqrtLimit
		));
		// Apply 2% downward slippage margin
		tokensOut = (tokensOut * 98n) / 100n;
	} else {
		({ tokensIn, tokensOut } = await pool.computeExpectedTokensIn(
			tokenIn,
			amount,
			sqrtPriceX96,
			sqrtLimit
		));
		// Apply 2% upward slippage margin
		tokensIn = (tokensIn * 102n) / 100n;
	}

	return { poolAddress, zeroForOne, tokensIn, tokensOut };
}

/**
 * Executes a swap (exactIn or exactOut) after ensuring approval.
 */
async function executeSwap(signer, tokenIn, tokenOut, amount, exactIn = true) {
	const { poolAddress, zeroForOne, tokensIn, tokensOut } = await estimateSwap(
		signer,
		tokenIn,
		tokenOut,
		amount,
		exactIn
	);

	await ensureApproval(signer, tokenIn, tokensIn);

	const swapper = new ethers.Contract(SWAPPER_ADDRESS, swapperAbi, signer);

	if (exactIn) {
		const tx = await swapper.swapV3ExactIn(poolAddress, zeroForOne, tokensIn, tokensOut);
		return await tx.wait();
	} else {
		const tx = await swapper.swapV3ExactOut(poolAddress, zeroForOne, tokensOut, tokensIn);
		return await tx.wait();
	}
}
