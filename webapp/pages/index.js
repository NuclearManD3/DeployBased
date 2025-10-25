(async () => {
	if (!window.signer && window.ethereum) {
		await checkWalletConnection();
	}

	const tokenListElem = document.getElementById('token-list');
	if (!tokenListElem) return;

	async function renderTokenList() {
		showSpinner(true);
		tokenListElem.innerHTML = '';

		const tokensFromChain = await fetchTokensFromFactory();
		if (!tokensFromChain.length) {
			tokenListElem.innerHTML = '<div class="token-item">No tokens found (or factory not configured)</div>';
		} else {
			tokensFromChain.forEach(token => {
				const item = document.createElement('div');
				item.classList.add('token-item');
				const label = token.name || token.symbol || token.address;
				const sym = token.symbol || '';
				item.innerHTML = `<a href="token.html?address=${token.address}">${label} ${sym ? `(${sym})` : ''}</a>`;
				tokenListElem.appendChild(item);
			});
		}
		showSpinner(false);
	}

	renderTokenList();
})();
