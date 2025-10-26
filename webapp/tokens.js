// tokenInfo.js
// Simple persistent token info cache

const TOKEN_INFO_KEY = 'tokenInfoCache_v1';
let tokenCache = JSON.parse(localStorage.getItem(TOKEN_INFO_KEY) || '{}');

// Persist cache
function saveCache() {
	localStorage.setItem(TOKEN_INFO_KEY, JSON.stringify(tokenCache));
}

// Get read-only provider (adjust as needed)
async function getReadProvider() {
	if (!window.readProvider)
		window.readProvider = new ethers.providers.JsonRpcProvider('https://mainnet.base.org');
	return window.readProvider;
}

async function _getTokenContract(address, signer=null) {
	const abi = [
		'function name() view returns (string)',
		'function symbol() view returns (string)',
		'function decimals() view returns (uint8)',
		'function owner() view returns (address)',
		'function totalSupply() view returns (uint256)',
		'function balanceOf(address) view returns (uint256)',
        'function allowance(address owner, address spender) view returns (uint256)',
        'function approve(address spender, uint256 value) returns (bool)'
	];
	if (signer == null)
	    signer = await getReadProvider();
	return new ethers.Contract(address, abi, signer);
}

async function _fetchTokenField(address, field) {
	try {
		const contract = await _getTokenContract(address);
		const val = await contract[field]();
		return val;
	} catch (err) {
		console.error(`Failed to fetch ${field} for ${address}:`, err);
		return null;
	}
}

async function getTokenSymbol(address) {
	address = address.toLowerCase();
	if (tokenCache[address]?.symbol) return tokenCache[address].symbol;
	const contract = await _getTokenContract(address);
	const symbol = await contract.symbol();
	tokenCache[address] = { ...(tokenCache[address] || {}), symbol };
	saveCache();
	return symbol;
}

async function getTokenName(address) {
	address = address.toLowerCase();
	if (tokenCache[address]?.name) return tokenCache[address].name;
	const contract = await _getTokenContract(address);
	const name = await contract.name();
	tokenCache[address] = { ...(tokenCache[address] || {}), name };
	saveCache();
	return name;
}

async function getTokenDecimals(address) {
	address = address.toLowerCase();
	if (tokenCache[address]?.decimals !== undefined)
		return tokenCache[address].decimals;
	const contract = await _getTokenContract(address);
	const decimals = await contract.decimals();
	tokenCache[address] = { ...(tokenCache[address] || {}), decimals };
	saveCache();
	return decimals;
}

async function getTokenSupply(address) {
	address = address.toLowerCase();
	if (tokenCache[address]?.supply) return tokenCache[address].supply;
	const contract = await _getTokenContract(address);
	const decimals = await getTokenDecimals(address);
	const totalSupply = await contract.totalSupply();
	const formatted = ethers.utils.formatUnits(totalSupply, decimals);
	tokenCache[address] = { ...(tokenCache[address] || {}), supply: formatted };
	saveCache();
	return formatted;
}

async function getTokenOwner(address) {
	address = address.toLowerCase();
	if (tokenCache[address]?.owner) return tokenCache[address].owner;
	const contract = await _getTokenContract(address);
	const owner = await contract.owner();
	tokenCache[address] = { ...(tokenCache[address] || {}), owner: owner };
	saveCache();
	return owner;
}

// Always fetch fresh
async function getTokenBalance(address, holder) {
	const contract = await _getTokenContract(address);
	const decimals = await getTokenDecimals(address);
	const balance = await contract.balanceOf(holder);
	return ethers.utils.formatUnits(balance, decimals);
}

async function getTokenApprovalRaw(address, holder, spender) {
	const contract = await _getTokenContract(address);
	//const decimals = await getTokenDecimals(address);
	const balance = await contract.allowance(holder, spender);
	return balance; //ethers.utils.formatUnits(balance, decimals);
}

async function setTokenApprovalRaw(signer, address, spender, amount) {
	const contract = await _getTokenContract(address, signer);
	//const decimals = await getTokenDecimals(address);
	return await contract.approve(spender, amount);
}
