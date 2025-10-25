// poolInfo.js
// Persistent pool utilities for modified V3-compatible pools

const POOL_INFO_KEY = 'poolInfoCache_v1';
let poolCache = JSON.parse(localStorage.getItem(POOL_INFO_KEY) || '{}');

function savePoolCache() {
	localStorage.setItem(POOL_INFO_KEY, JSON.stringify(poolCache));
}

async function _getPoolContract(address, signer = null) {
	const abi = [
		'function token0() view returns (address)',
		'function token1() view returns (address)',
		'function fee() view returns (uint24)',
		'function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 observationIndex,uint16 observationCardinality,uint16 observationCardinalityNext,uint8 feeProtocol,bool unlocked)',
		'function collect(address recipient,int24 tickLower,int24 tickUpper,uint128 amount0Requested,uint128 amount1Requested) returns (uint128 amount0,uint128 amount1)',
		'function reserve() view returns (address)',
		'function launch() view returns (address)',
		'function computeExpectedTokensOut(address inputToken,uint256 maxTokensIn,uint160 sqrtPriceX96,uint160 sqrtPriceLimitX96) view returns (uint256 tokensIn,uint256 tokensOut,uint160 newSqrtPriceX96)',
		'function computeExpectedTokensIn(address inputToken,uint256 maxTokensOut,uint160 sqrtPriceX96,uint160 sqrtPriceLimitX96) view returns (uint256 tokensIn,uint256 tokensOut,uint160 newSqrtPriceX96)',
		'function owner() view returns (address)'
	];
	if (signer == null)
		signer = await getReadProvider();
	return new ethers.Contract(address, abi, signer);
}

async function getPoolOwner(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.owner) return poolCache[address].owner;
	const contract = await _getPoolContract(address);
	const owner = await contract.owner();
	poolCache[address] = { ...(poolCache[address] || {}), owner: owner };
	savePoolCache();
	return owner;
}

async function getPoolToken0(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.token0) return poolCache[address].token0;
	const pool = await _getPoolContract(address);
	const token0 = await pool.token0();
	poolCache[address] = { ...(poolCache[address] || {}), token0 };
	savePoolCache();
	return token0;
}

async function getPoolToken1(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.token1) return poolCache[address].token1;
	const pool = await _getPoolContract(address);
	const token1 = await pool.token1();
	poolCache[address] = { ...(poolCache[address] || {}), token1 };
	savePoolCache();
	return token1;
}

async function getPoolFee(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.fee) return poolCache[address].fee;
	const pool = await _getPoolContract(address);
	const fee = await pool.fee();
	poolCache[address] = { ...(poolCache[address] || {}), fee: parseInt(fee) };
	savePoolCache();
	return fee;
}

// Converts sqrtPriceX96 to normal price, adjusted for token decimals
async function getCurrentPrice(address) {
	const pool = await _getPoolContract(address);
	const [token0, token1] = await Promise.all([
		getPoolToken0(address),
		getPoolToken1(address)
	]);
	const [dec0, dec1] = await Promise.all([
		getTokenDecimals(token0),
		getTokenDecimals(token1)
	]);
	const slot0 = await pool.slot0();
	const sqrtPriceX96 = slot0.sqrtPriceX96;

	// Price = (sqrtPriceX96 / 2^96)^2 * (10^(dec0 - dec1))
	const ratio = (Number(sqrtPriceX96) / (2 ** 96)) ** 2;
	const adjusted = ratio * (10 ** (dec0 - dec1));

	// Assuming reserve = token0, launch = token1
	return adjusted;
}

async function getFeePercent(address) {
	const fee = await getPoolFee(address);
	// Fee is in hundredths of a bip (1e-6)
	// Add 0.5% markup as per your note
	return (fee / 1e4) + 0.5;
}

async function collectFees(signer, poolAddr, recipient, tickLower, tickUpper, amount0Requested, amount1Requested) {
	const pool = await _getPoolContract(poolAddr, signer);
	const tx = await pool.collect(recipient, tickLower, tickUpper, amount0Requested, amount1Requested);
	return await tx.wait();
}

async function estimateTokensOut(poolAddr, inputToken, maxTokensIn, sqrtPriceX96, sqrtPriceLimitX96) {
	const pool = await _getPoolContract(poolAddr);
	const result = await pool.computeExpectedTokensOut(inputToken, maxTokensIn, sqrtPriceX96, sqrtPriceLimitX96);
	return {
		tokensIn: result.tokensIn,
		tokensOut: result.tokensOut,
		newSqrtPriceX96: result.newSqrtPriceX96
	};
}

async function estimateTokensIn(poolAddr, inputToken, maxTokensOut, sqrtPriceX96, sqrtPriceLimitX96) {
	const pool = await _getPoolContract(poolAddr);
	const result = await pool.computeExpectedTokensIn(inputToken, maxTokensOut, sqrtPriceX96, sqrtPriceLimitX96);
	return {
		tokensIn: result.tokensIn,
		tokensOut: result.tokensOut,
		newSqrtPriceX96: result.newSqrtPriceX96
	};
}
