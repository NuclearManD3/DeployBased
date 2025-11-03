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
		'function owner() view returns (address)',
		'function curveParams() external view returns (uint256 minPrice, uint256 multiple, uint256 limit, uint256 offset)',
		'function reserves() public view returns (uint128 r0, uint128 r1)'
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

async function getPoolReserveToken(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.reserve) return poolCache[address].reserve;
	const pool = await _getPoolContract(address);
	const reserve = await pool.reserve();
	poolCache[address] = { ...(poolCache[address] || {}), reserve };
	savePoolCache();
	return reserve;
}

async function getPoolLaunchToken(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.launch) return poolCache[address].launch;
	const pool = await _getPoolContract(address);
	const launch = await pool.launch();
	poolCache[address] = { ...(poolCache[address] || {}), launch };
	savePoolCache();
	return launch;
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

// Converts sqrtPriceX96 to normal price, adjusted for token decimals and converted to reserve/launch
async function getCurrentPrice(address) {
	const pool = await _getPoolContract(address);
	console.log(pool, address);
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
	let adjusted = ratio * (10 ** (dec0 - dec1));

	if (await getPoolReserveToken(address) == token0)
		adjusted = 1 / adjusted;

	return Math.round(adjusted * 100000000) / 100000000;
}

// Converts sqrtPriceX96 to normal price, adjusted for token decimals and converted to reserve/launch
async function getPoolReserves(address) {
	const pool = await _getPoolContract(address);
	const reservesRaw = await pool.reserves();
	const [token0, token1] = await Promise.all([
		getPoolToken0(address),
		getPoolToken1(address)
	]);
	const [dec0, dec1] = await Promise.all([
		getTokenDecimals(token0),
		getTokenDecimals(token1)
	]);

	if (await getPoolReserveToken(address) == token1)
		return {
			reserve: reservesRaw.r1 / (10 ** dec1),
			launch: reservesRaw.r0 / (10 ** dec0)
		};
	else
		return {
			reserve: reservesRaw.r0 / (10 ** dec0),
			launch: reservesRaw.r1 / (10 ** dec1)
		};
}

async function getPoolCurve(address) {
	address = address.toLowerCase();
	if (poolCache[address]?.curve) return poolCache[address].curve;

	const pool = await _getPoolContract(address);
	const [reserve, launch] = await Promise.all([
		getPoolReserveToken(address),
		getPoolLaunchToken(address)
	]);
	const [dec0, dec1] = await Promise.all([
		getTokenDecimals(reserve),
		getTokenDecimals(launch)
	]);
	let curve = await pool.curveParams();

	const minPriceRaw = curve.minPrice;
	let basePrice = (2 ** 128) * (10 ** (dec1 - dec0)) / minPriceRaw;

	const multiple = (10 ** dec1) * curve.multiple / (2 ** 128) / curve.limit;

	const curveLimit = curve.limit / (10 ** dec0);

	const reserveOffset = curve.offset / (10 ** dec0);

	curve = {
		basePrice,
		multiple,
		curveLimit,
		reserveOffset
	}
	poolCache[address] = { ...(poolCache[address] || {}), curve };
	savePoolCache();
	return curve;
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
