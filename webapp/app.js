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
    testnet: '0x036CbD53842c5426634e7929541eC2318f3dcBB2' // Example, replace if needed
};
let currentNetwork = 'mainnet';

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

// Page-specific logic
async function loadData() {
    const path = window.location.pathname;
    if (path.endsWith('index.html') || path === '/' || path === '') {
        // Load token list from MongoDB/API, placeholder
        const tokenList = document.getElementById('token-list');
        tokenList.innerHTML = '';
        // Fetch from API or chain, placeholder data
        const tokens = [{name: 'Token1', symbol: 'TK1'}, {name: 'Token2', symbol: 'TK2'}]; // Replace with real fetch, e.g., fetch('/api/tokens')
        tokens.forEach(token => {
            const item = document.createElement('div');
            item.classList.add('token-item');
            item.innerHTML = `<a href="token.html?symbol=${token.symbol}">${token.name} (${token.symbol})</a>`;
            tokenList.appendChild(item);
        });
    } else if (path.endsWith('about.html')) {
        // Total tokens, placeholder
        document.getElementById('total-tokens').innerText = '42'; // Fetch from API/chain
    } else if (path.endsWith('mytokens.html')) {
        if (!account) return;
        const myTokenList = document.getElementById('my-token-list');
        myTokenList.innerHTML = '';
        // Fetch owned tokens from chain/Mongo, placeholder
        const tokens = [{name: 'MyToken', fees: '10 USDC'}];
        tokens.forEach(token => {
            const item = document.createElement('div');
            item.classList.add('token-item');
            item.innerHTML = `${token.name} - Fees: ${token.fees} <button onclick="collectFees('${token.name}')">Collect</button>`;
            myTokenList.appendChild(item);
        });
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
        // Load token details from query param
        const params = new URLSearchParams(window.location.search);
        const symbol = params.get('symbol');
        if (symbol) {
            document.getElementById('token-name').innerText = `${symbol} Token`;
            // Load more details via API or chain
        }
        document.getElementById('buy-token').addEventListener('click', async () => {
            if (!signer) {
                showError('Connect wallet first');
                return;
            }
            showSpinner(true);
            try {
                // Call buy function
                const tx = await buyToken(/* params including symbol */);
                await tx.wait();
            } catch (err) {
                showError(err.message);
            } finally {
                showSpinner(false);
            }
        });
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
