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
const usdcAddresses = {
	mainnet: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // USDC on Base
	testnet: '0xREPLACE_USDC_TESTNET'
};
const factoryAddresses = {
	mainnet: '0x13f92684Ac881b81fb5953951072B82700AE9e7d',
	testnet: '0xREPLACE_FACTORY_TESTNET'
};

const factoryAbi = [
    'function totalTokens() view returns (uint256)',
    'function tokens(uint256) view returns (address)'
];

const erc20ReadAbi = [
	'function name() view returns (string)',
	'function symbol() view returns (string)',
	'function decimals() view returns (uint8)'
];

const MAX_TOKENS_FETCH = 200; // safety cap to avoid huge loops
// ----------------------------------------------------------------

let currentNetwork = 'mainnet';

// simple in-memory cache to avoid repeated RPC calls
const tokenCache = {
	network: null,
	ts: 0,
	ttl: 60 * 1000, // 60s cache
	tokens: []
};

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
							blockExplorerUrls: [currentNetwork === 'mainnet' ? 'https://basescan.org/' : 'https://sepolia.basescan.org/']
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
	const usdcContract = new ethers.Contract(usdcAddresses[currentNetwork], ['function balanceOf(address) view returns (uint256)'], signer);
	const balance = await usdcContract.balanceOf(account);
	document.getElementById('usdc-balance').innerText = `USDC: ${ethers.utils.formatUnits(balance, 6)}`;
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
	if (provider) {
		await switchNetwork();
		await updateUSDCBalance();
		loadData();
	}
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

async function fetchTokensFromFactory() {
	// use cache
	if (tokenCache.network === currentNetwork && (Date.now() - tokenCache.ts) < tokenCache.ttl) {
		return tokenCache.tokens;
	}

	const readProvider = await getReadProvider();
	const factoryAddress = factoryAddresses[currentNetwork];
	if (!factoryAddress || factoryAddress === '0xREPLACE_FACTORY_MAINNET' || factoryAddress === '0xREPLACE_FACTORY_TESTNET') {
		// no factory configured; return empty to avoid RPC spam
		return [];
	}

	const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);
	let total = 0;
	try {
		const totalBN = await factory.totalTokens();
		total = Math.min(totalBN.toNumber(), MAX_TOKENS_FETCH);
	} catch (err) {
		console.error('Failed to read totalTokens()', err);
		return [];
	}

	const out = [];
	// SERIAL fetch to avoid spamming RPC with parallel calls
	for (let i = 0; i < total; i++) {
		try {
			const tokenAddr = await factory.tokens(i);
			// read name/symbol/decimals with sequential calls
			const tokenContract = new ethers.Contract(tokenAddr, erc20ReadAbi, readProvider);
			let name = 'Unknown';
			let symbol = '';
			let decimals = 18;
			try { name = await tokenContract.name(); } catch (e) { /* ignore */ }
			try { symbol = await tokenContract.symbol(); } catch (e) { /* ignore */ }
			try { decimals = await tokenContract.decimals(); } catch (e) { /* ignore */ }
			out.push({ address: tokenAddr, name, symbol, decimals: Number(decimals) });
		} catch (err) {
			console.warn('Failed to fetch token at index', i, err);
			// continue quietly; don't abort the whole loop
		}
	}

	// update cache
	tokenCache.network = currentNetwork;
	tokenCache.ts = Date.now();
	tokenCache.tokens = out;
	return out;
}

let renderTokenListLock = false;
async function renderTokenList() {
	if (renderTokenListLock)
		return;
	renderTokenListLock = true;
	showSpinner(true);
	const tokenList = document.getElementById('token-list');
	tokenList.innerHTML = '';
	const tokensFromChain = await fetchTokensFromFactory();
	if (!tokensFromChain.length) {
		tokenList.innerHTML = '<div class="token-item">No tokens found (or factory not configured)</div>';
	} else {
		tokensFromChain.forEach(token => {
			const item = document.createElement('div');
			item.classList.add('token-item');
			const label = token.name || token.symbol || token.address;
			const sym = token.symbol || '';
			item.innerHTML = `<a href="token.html?address=${token.address}&symbol=${encodeURIComponent(sym)}">${label} ${sym ? `(${sym})` : ''}</a>`;
			tokenList.appendChild(item);
		});
	}
	showSpinner(false);
	renderTokenListLock = false;
}

// Page-specific logic
async function loadData() {
	const path = window.location.pathname;
	if (path.endsWith('index.html') || path === '/' || path === '') {
		await renderTokenList();
	} else if (path.endsWith('about.html')) {
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

	} else if (path.endsWith('mytokens.html')) {
		if (!account) return;
		const myTokenList = document.getElementById('my-token-list');
		if (!myTokenList) return;
		myTokenList.innerHTML = '';
		showSpinner(true);

		try {
			const readProvider = await getReadProvider();
			const factoryAddress = factoryAddresses[currentNetwork];
			if (!factoryAddress) {
				myTokenList.innerHTML = '<div class="token-item">Factory not configured.</div>';
				return;
			}

			const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);
			const totalBN = await factory.totalTokens();
			const total = Math.min(totalBN.toNumber(), MAX_TOKENS_FETCH);
			const owned = [];

			for (let i = 0; i < total; i++) {
				const addr = await factory.tokens(i);
				const tokenContract = new ethers.Contract(addr, [
					...erc20ReadAbi,
					'function owner() view returns (address)'
				], readProvider);

				let symbol = '', name = '', ownerAddr = '';
				try { symbol = await tokenContract.symbol(); } catch {}
				try { name = await tokenContract.name(); } catch {}
				try { ownerAddr = await tokenContract.owner(); } catch {}

				if (ownerAddr.toLowerCase() === account.toLowerCase()) {
					owned.push({
						address: addr,
						name: name || symbol || 'Unknown',
						symbol
					});
				}
			}

			if (!owned.length) {
				myTokenList.innerHTML = '<div class="token-item">You do not own any tokens.</div>';
			} else {
				owned.forEach(tok => {
					const item = document.createElement('div');
					item.classList.add('token-item');
					item.innerHTML = `
						${tok.name} (${tok.symbol})<br>
						<button onclick="collectFees('${tok.address}')">Collect Fees</button>
					`;
					myTokenList.appendChild(item);
				});
			}

		} catch (err) {
			console.error('Error loading my tokens:', err);
			myTokenList.innerHTML = '<div class="token-item">Error fetching your tokens.</div>';
		} finally {
			showSpinner(false);
		}
	} else if (path.endsWith('deploy.html')) {
        // Sliders update
        document.getElementById('initial-market-cap').addEventListener('input', (e) => {
            document.getElementById('initial-market-cap-value').innerText = e.target.value;
        });
        document.getElementById('liquidity-assistance').addEventListener('input', (e) => {
            document.getElementById('liquidity-assistance-value').innerText = `${e.target.value}%`;
        });
        document.getElementById('tokens-to-purchase').addEventListener('input', (e) => {
            document.getElementById('tokens-to-purchase-value').innerText = `${e.target.value}%`;
        });

        document.getElementById('deploy-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            if (!signer) {
                showError('Connect wallet first');
                return;
            }
            showSpinner(true);
            try {
                // Gather form data
                const name = document.getElementById('token-name').value;
                const symbol = document.getElementById('token-symbol').value;
                // ... other fields
                // Call contract deploy function from contracts.js
                const tx = await deployToken(/* params */);
                await tx.wait();
                // Redirect to token page
                window.location.href = `token.html?symbol=${symbol}`;
            } catch (err) {
                showError(err.message);
            } finally {
                showSpinner(false);
            }
        });
    } else if (path.endsWith('token.html')) {
		const params = new URLSearchParams(window.location.search);
		const tokenAddress = params.get('address');
		if (!tokenAddress) return;

		const tokenNameElem = document.getElementById('token-name');
		const tokenDetailsElem = document.getElementById('token-details');

		tokenNameElem.innerText = 'Loading...';
		tokenDetailsElem.innerHTML = '';
		showSpinner(true);

		try {
			const readProvider = await getReadProvider();
			const tokenContract = new ethers.Contract(tokenAddress, [
				'function name() view returns (string)',
				'function symbol() view returns (string)',
				'function decimals() view returns (uint8)',
				'function totalSupply() view returns (uint256)',
				'function owner() view returns (address)'
			], readProvider);

			const [name, symbol, decimals, totalSupply, ownerAddr] = await Promise.all([
				tokenContract.name(),
				tokenContract.symbol(),
				tokenContract.decimals(),
				tokenContract.totalSupply(),
				tokenContract.owner()
			]);

			tokenNameElem.innerText = `${symbol} Token`;
			tokenDetailsElem.innerHTML = `
				<p><strong>Name:</strong> ${name}</p>
				<p><strong>Symbol:</strong> ${symbol}</p>
				<p><strong>Decimals:</strong> ${decimals}</p>
				<p><strong>Total Supply:</strong> ${ethers.utils.formatUnits(totalSupply, decimals)}</p>
				<p><strong>Owner:</strong> ${ownerAddr}</p>
			`;

			document.getElementById('buy-token').addEventListener('click', async () => {
				if (!signer) {
					showError('Connect wallet first');
					return;
				}
				showSpinner(true);
				try {
					const tx = await buyToken(tokenAddress);
					await tx.wait();
					showError('Purchase successful!');
				} catch (err) {
					showError(err.message);
				} finally {
					showSpinner(false);
				}
			});

		} catch (err) {
			console.error('Error loading token:', err);
			tokenNameElem.innerText = 'Error';
			tokenDetailsElem.innerHTML = 'Could not fetch token info.';
		} finally {
			showSpinner(false);
		}
	}
}

async function collectFees(tokenName) {
	if (!signer) return;
	showSpinner(true);
	try {
		// Call collect fees from contracts.js
		const tx = await collectTokenFees(tokenName);
		await tx.wait();
	} catch (err) {
		showError(err.message);
	} finally {
		showSpinner(false);
	}
}

// Initial load
checkWalletConnection();
loadData();
