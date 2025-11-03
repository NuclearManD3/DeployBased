// app.js
let provider;
let signer;
let account;

const chainIds = {
	mainnet: 8453, // Base mainnet
	testnet: 84532 // Base Sepolia testnet
};

const rpcUrls = {
	mainnet: 'https://mainnet.base.org',
	testnet: 'https://sepolia.base.org'
};

const explorerUrls = {
	mainnet: 'https://basescan.org',
	testnet: 'https://sepolia.basescan.org'
}

const usdcAddresses = {
	mainnet: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // USDC on Base
	testnet: '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
};

const factoryAddresses = {
	mainnet: '0x88B49d6F0BC138f52C60B33CaB2245ADe9597189',
	testnet: '0x1be2351ce3840de7eea5f701688427606cd55c79'
};

const tokenAddresses = {
	mainnetUSDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
	testnetUSDC: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
	mainnetWETH: '0x4200000000000000000000000000000000000006',
	testnetWETH: '0x4200000000000000000000000000000000000006',
	mainnetUSDS: '0x820C137fa70C8691f0e44Dc420a5e53c168921Dc'
}

const tokenDecimals = {
	mainnetUSDC: 6,
	testnetUSDC: 6,
	mainnetWETH: 18,
	testnetWETH: 18,
	mainnetUSDS: 18
}

const factoryAbi = [
	'function totalTokens() view returns (uint256)',
	'function tokens(uint256) view returns (address)',
	'function launchToken(string memory, string memory, string memory, uint8, address, uint24, uint256, uint256, uint96, uint128, uint128) returns (address, address)',
	'function listManyTokens(int256 start, int256 end) external view returns (address[] memory array)',
	'function listManyTokenDetails(int256 start, int256 end) external view returns (tuple(address token, address owner, string name, string symbol)[] memory array)',
	'event TokenCreated(address indexed token, uint8 decimals, string name, string symbol)'
];

const MAX_TOKENS_FETCH = 50; // safety cap to avoid huge loops
// ----------------------------------------------------------------

let currentNetwork = 'mainnet';

function usdcAddress() {
	return usdcAddresses[currentNetwork];
}

function explorer() {
	return explorerUrls[currentNetwork];
}

async function setCurrentNetwork() {
	const network = await provider.getNetwork();
	const chainId = network.chainId;
	if (chainId === chainIds.mainnet) {
		currentNetwork = 'mainnet';
	} else if (chainId === chainIds.testnet) {
		currentNetwork = 'testnet';
	} else {
		// Switch to default if unsupported
		currentNetwork = 'mainnet';
		await switchNetwork();
		return;
	}
	document.getElementById('network-switch').value = currentNetwork;
}

// Wallet connection logic
async function connectWallet() {
	if (!window.ethereum) {
		showError('Please install MetaMask!');
		return;
	}

	try {
		// Request account access
		await window.ethereum.request({ method: 'eth_requestAccounts' });
		provider = new ethers.providers.Web3Provider(window.ethereum);
		signer = provider.getSigner();
		account = await signer.getAddress();

		// Set current network based on connected chain
		await setCurrentNetwork();

		document.getElementById('connect-wallet').classList.add('hidden');
		document.getElementById('wallet-info').classList.remove('hidden');
		await updateUSDCBalance();
		loadData();
	} catch (err) {
		showError('Connection failed: ' + (err.message || 'Unknown error'));
	}
}

function makeAddressHTML(label, addr, root = "/address/") {
	//const shortAddr = addr.slice(0, 6) + '...' + addr.slice(-4);
	const link = explorer() + root + addr;
	return `
		<p><strong>${label}:</strong>
			<a href="${link}" target="_blank" class="ext-link">
				${addr}
				<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" style="margin-left:3px;vertical-align:middle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
					<path d="M18 13v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
					<polyline points="15 3 21 3 21 9" />
					<line x1="10" y1="14" x2="21" y2="3" />
				</svg>
			</a>
			<button class="copy-btn" data-addr="${addr}" title="Copy address">
				<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" style="vertical-align:middle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
					<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
					<path d="M5 15H4a2 2 0 0 1-2-2V4
						a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
				</svg>
			</button>
		</p>
	`;
}

function renderTokenCard(tok) {
	const card = document.createElement('div');
	card.classList.add('token-card');
	card.innerHTML = `
		<div class="token-header">
			<a href="token.html?address=${tok.address}" class="token-link">${tok.name} (${tok.symbol})</a>
		</div>
		<div class="token-explorer">
			${makeAddressHTML("Token address", tok.address, "/token/")}
		</div>
	`;
	// Copy button logic
	card.querySelectorAll('.copy-btn').forEach(btn => {
		btn.addEventListener('click', async () => {
			try {
				await navigator.clipboard.writeText(btn.dataset.addr);
				btn.innerHTML = '✓';
				setTimeout(() => {
					btn.innerHTML = `
						<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" style="vertical-align:middle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
							<path d="M5 15H4a2 2 0 0 1-2-2V4 a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
						</svg>`;
				}, 1000);
			} catch (err) {
				console.error('Copy failed:', err);
			}
		});
	});
	return card;
}

async function renderList(container, generator, renderItem) {
	// clear container
	container.innerHTML = '';
	showSpinner(true);

	try {
		for await (const item of generator) {
			const card = renderItem(item);
			container.appendChild(card);
		}
	} catch (err) {
		console.error('Error rendering list:', err);
		container.innerHTML = '<div class="token-item">Error loading items.</div>';
	} finally {
		showSpinner(false);
	}
}



async function checkWalletConnection() {
	if (!window.ethereum) return;

	try {
		const accounts = await window.ethereum.request({ method: 'eth_accounts' });
		if (accounts.length > 0) {
			provider = new ethers.providers.Web3Provider(window.ethereum);
			signer = provider.getSigner();
			account = accounts[0];

			// Set current network based on connected chain
			await setCurrentNetwork();

			document.getElementById('connect-wallet').classList.add('hidden');
			document.getElementById('wallet-info').classList.remove('hidden');
			await updateUSDCBalance();
			loadData();
		}
	} catch (err) {
		// Silent fail if not connected
	}
}

async function switchNetwork() {
	const chainIdHex = '0x' + chainIds[currentNetwork].toString(16);
	try {
		await window.ethereum.request({
			method: 'wallet_switchEthereumChain',
			params: [{ chainId: chainIdHex }],
		});
	} catch (switchError) {
		if (switchError.code === 4902) {
			try {
				await window.ethereum.request({
					method: 'wallet_addEthereumChain',
					params: [
						{
							chainId: chainIdHex,
							chainName: currentNetwork === 'mainnet' ? 'Base Mainnet' : 'Base Sepolia Testnet',
							nativeCurrency: {
								name: 'Ether',
								symbol: 'ETH',
								decimals: 18
							},
							rpcUrls: [rpcUrls[currentNetwork]],
							blockExplorerUrls: [explorer()]
						}
					]
				});
			} catch (addError) {
				showError('Failed to add network: ' + addError.message);
			}
		} else {
			showError('Failed to switch network: ' + switchError.message);
		}
	}
}

function disconnectWallet() {
	account = null;
	signer = null;
	provider = null;
	document.getElementById('connect-wallet').classList.remove('hidden');
	document.getElementById('wallet-info').classList.add('hidden');
	document.getElementById('usdc-balance').innerText = '';
	loadData();
}

async function updateUSDCBalance() {
	if (!signer) return;
	const balance = await getTokenBalance(usdcAddresses[currentNetwork], account);
	document.getElementById('usdc-balance').innerText = `USDC: ${balance}`;
}

function showSpinner(show) {
	document.getElementById('loading-spinner').classList.toggle('hidden', !show);
}

function showError(message) {
	const errorDiv = document.getElementById('error-message');
	if (errorDiv) {
		errorDiv.innerText = message;
		errorDiv.classList.remove('hidden');
	} else {
		alert(message);
	}
}

// Network switch listener
document.getElementById('network-switch').addEventListener('change', async (e) => {
	currentNetwork = e.target.value;
	await switchNetwork();
	await checkWalletConnection();
});

// Connect/Disconnect buttons
document.getElementById('connect-wallet').addEventListener('click', connectWallet);
document.getElementById('disconnect-wallet').addEventListener('click', disconnectWallet);

// MetaMask event listeners
if (window.ethereum) {
	window.ethereum.on('accountsChanged', (accounts) => {
		if (accounts.length > 0) {
			account = accounts[0];
			updateUSDCBalance();
			loadData();
		} else {
			disconnectWallet();
		}
	});

	window.ethereum.on('chainChanged', async (chainId) => {
		const newChainId = parseInt(chainId);
		if (newChainId === chainIds.mainnet) {
			currentNetwork = 'mainnet';
		} else if (newChainId === chainIds.testnet) {
			currentNetwork = 'testnet';
		} else {
			showError('Switched to unsupported network. Please switch back to Base.');
			return;
		}
		document.getElementById('network-switch').value = currentNetwork;
		if (account) {
			await updateUSDCBalance();
			loadData();
		}
	});
}


// Fetch from API or chain, placeholder data
// Use connected wallet provider for eth_call when possible (falls back to RPC URL)
async function getReadProvider() {
	if (provider) return provider;
	// fallback readonly provider (kept as last resort)
	return new ethers.providers.JsonRpcProvider(rpcUrls[currentNetwork]);
}

// Fetches a range of token addresses from the factory contract
async function listManyTokens(start, end) {
	try {
		const readProvider = await getReadProvider();
		const factoryAddress = factoryAddresses[currentNetwork];
		if (!factoryAddress) {
			throw new Error('Factory address not found for current network');
		}
		const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);
		const tokenAddresses = await factory.listManyTokens(start, end);
		return tokenAddresses; // Returns array of addresses
	} catch (err) {
		console.warn(`Failed to fetch tokens from ${start} to ${end}:`, err);
		return [];
	}
}

// Fetches detailed token information for a range of tokens
async function listManyTokenDetails(start, end) {
	try {
		const readProvider = await getReadProvider();
		const factoryAddress = factoryAddresses[currentNetwork];
		if (!factoryAddress) {
			throw new Error('Factory address not found for current network');
		}
		const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);
		const tokenDetails = await factory.listManyTokenDetails(start, end);
		// Map tuple array to objects for easier front-end use
		return tokenDetails.map(detail => ({
			token: detail.token,
			owner: detail.owner,
			name: detail.name,
			symbol: detail.symbol
		}));
	} catch (err) {
		console.warn(`Failed to fetch token details from ${start} to ${end}:`, err);
		return [];
	}
}

// Generates a pool price/slippage widget
// containerId: ID of container div
// params: {
//   totalSupply, tokenPriceUSD, currentPrice, currentInvestment,
//   p0, curveLimit, M, b
// }
async function createPoolPriceWidget(containerId, params) {
	const container = document.getElementById(containerId);
	if (!container) return;

	// Clear previous content
	container.innerHTML = '';

	// Market Cap display
	const marketCapDiv = document.createElement('div');
	marketCapDiv.style.marginBottom = '10px';
	marketCapDiv.style.fontWeight = 'bold';
	container.appendChild(marketCapDiv);

	const supply = params.totalSupply;
	const marketCap = supply * params.tokenPriceUSD;
	marketCapDiv.innerText = `Market Cap: $${marketCap.toLocaleString(undefined, {maximumFractionDigits:2})}`;

	const chartDiv = document.createElement('div');
	chartDiv.id = containerId + '_chart-container';
	container.appendChild(chartDiv);

	// Calculate the price curve points
	const xs = [];
	const ys = [];
	const step = params.curveLimit / 50; // linear segment steps
	let maxX = params.curveLimit * 10; // arbitrary max for xy=K portion
	const yAtLimit = supply - params.curveLimit / (params.p0 + params.M * params.curveLimit / 2)
	const K = (params.curveLimit + params.b) * yAtLimit;
	console.log(supply, params.curveLimit, params.p0, params.M, yAtLimit, K);

	// Linear portion
	for (let dx = 0; dx <= params.curveLimit; dx += step) {
		const price = params.p0 + params.M * dx;
		xs.push(dx);
		ys.push(price);
	}

	// xy=K portion
	for (let dx = params.curveLimit + step; dx <= maxX; dx += step) {
		let vx = params.b + dx;
		let y1 = K / vx;
		const price = vx / y1;
		xs.push(dx);
		ys.push(price);
	}

	var data = [ {
		x: xs,
		y: ys,
		mode: 'lines',
		name: 'Price',
		line: {
			color: 'rgb(64, 82, 219)',
			width: 3
		}
	}, {
		x: [params.currentInvestment],
		y: [params.currentPrice],
		name: "Current Price",
		mode: 'markers',
		type: 'scatter',
		marker: {
			size: 10,
			color: "#FFFF00",
			sizemode: 'area'
		}
	} ];

	var layout = {
		title: {text: 'Price vs Cumulative Purchases'},
		plot_bgcolor: "#181a1f",
		paper_bgcolor: "#181a1f",
		text_color: "#D0D0F0",
		font: {
			family: 'sans serif',
			size: 14,
			color: "#C0C0F0"
		},
	};

	Plotly.newPlot(chartDiv.id, data, layout);
}


// Page-specific logic
let inLoading = false;
async function loadData() {
	if (inLoading) return;
	inLoading = true;
	const path = window.location.pathname;
	if (path.endsWith('about.html')) {
		const totalTokensElem = document.getElementById('total-tokens');
		if (!totalTokensElem) return;

		try {
			const readProvider = await getReadProvider();
			const factoryAddress = factoryAddresses[currentNetwork];
			if (!factoryAddress) return;
			const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);
			const total = await factory.totalTokens();
			totalTokensElem.innerText = total.toString();
		} catch (err) {
			console.warn('Failed to fetch total token count:', err);
			totalTokensElem.innerText = '?';
		}
	}

	try {
		// Optionally, a page may define this to catch this event
		await refreshPageDetails();
	} catch (e) {
		console.log(e);
	}

	inLoading = false;
}

// Initial load
checkWalletConnection();

