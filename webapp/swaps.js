// swaps.js

const FACTORY_ADDRESS = {
	mainnet: '0x263a00623e00e135ec1810280d491c0fd4e5b8dd',
	testnet: '0xbbf057efe3e96f20533e43b7423f792a0af0dfeb'
};
const SWAPPER_ADDRESS = {
	mainnet: '0x828f0508971c67f472b7dd52155b5850a68cec86',
	testnet: '0xe062c6ddBa660F19Fd455c02EbA146e0D937ADb5'
};
const FEE_TIER = 10000; // 1%

const SQRT_PRICE_LIMIT_UP = 0x1000000000n;
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

/**
 * Ensures SwapperV3 can spend user's tokens.
 */
async function ensureApproval(signer, token, amount) {
	const owner = await signer.getAddress();
	const allowance = await getTokenApprovalRaw(token, owner, SWAPPER_ADDRESS[currentNetwork]);
	if (allowance.lt(amount)) {
		const tx = await setTokenApprovalRaw(signer, token, SWAPPER_ADDRESS[currentNetwork], SQRT_PRICE_LIMIT_DOWN);
		await tx.wait();
	}
}


async function findPoolForTokens(token0, token1) {
	const factory = new ethers.Contract(FACTORY_ADDRESS[currentNetwork], poolFactoryAbi, await getReadProvider());
	return await factory.getPool(token0, token1, FEE_TIER);
}

/**
 * Estimates output or input for swap with slippage margin.
 */
async function estimateSwap(signer, tokenIn, tokenOut, amount, exactIn = true) {
	console.log(signer, tokenIn, tokenOut, amount, exactIn);
	const factory = new ethers.Contract(FACTORY_ADDRESS[currentNetwork], poolFactoryAbi, signer.provider);
	const poolAddress = await factory.getPool(tokenIn, tokenOut, FEE_TIER);
	console.log("Pool: " + poolAddress);
	if (poolAddress === ethers.ZeroAddress) throw new Error('Pool not found');

	const pool = new ethers.Contract(poolAddress, poolAbi, signer.provider);
	const { sqrtPriceX96 } = await pool.slot0();
	console.log("sqrtPriceX96: " + sqrtPriceX96);

	const zeroForOne = tokenIn.toLowerCase() < tokenOut.toLowerCase();
	const sqrtLimit = zeroForOne ? SQRT_PRICE_LIMIT_UP : SQRT_PRICE_LIMIT_DOWN;

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
		tokensOut = tokensOut.mul(98n).div(100n);
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

	const swapper = new ethers.Contract(SWAPPER_ADDRESS[currentNetwork], swapperAbi, signer);

	if (exactIn) {
		const tx = await swapper.swapV3ExactIn(poolAddress, zeroForOne, tokensIn, tokensOut);
		return await tx.wait();
	} else {
		const tx = await swapper.swapV3ExactOut(poolAddress, zeroForOne, tokensOut, tokensIn);
		return await tx.wait();
	}
}
