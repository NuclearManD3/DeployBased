(async () => {
	if (!account) await connectWallet();

	const myTokenList = document.getElementById('my-token-list');
	if (!myTokenList) return;

	showSpinner(true);
	myTokenList.innerHTML = '';

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
			let name = '', symbol = '', ownerAddr = '';
			try { name = await getTokenName(addr); } catch {}
			try { symbol = await getTokenSymbol(addr); } catch {}
			try { ownerAddr = await getTokenOwner(addr); } catch {}

			if (ownerAddr.toLowerCase() === account.toLowerCase()) {
				owned.push({ address: addr, name: name || symbol || 'Unknown', symbol });
			}
		}

		if (!owned.length) {
			myTokenList.innerHTML = '<div class="token-item">You do not own any tokens.</div>';
		} else {
			owned.forEach(tok => {
				const card = document.createElement('div');
				card.classList.add('token-card'); // new card class for styling
				card.innerHTML = `
					<div class="token-header">
						<a href="token.html?address=${tok.address}" class="token-link">${tok.name} (${tok.symbol})</a>
					</div>
					<div class="token-explorer">
						${makeAddressHTML("Token address", tok.address, "https://basescan.org/token/")}
					</div>
				`;
				myTokenList.appendChild(card);
			});

			// Copy buttons
			document.querySelectorAll('.copy-btn').forEach(btn => {
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
		}

	} catch (err) {
		console.error('Error loading my tokens:', err);
		myTokenList.innerHTML = '<div class="token-item">Error fetching your tokens.</div>';
	} finally {
		showSpinner(false);
	}
})();
