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

        console.log('account: ', account);
		for (let i = 0; i < total; i++) {
			const addr = await factory.tokens(i);
			let name = '', symbol = '', ownerAddr = '';
			try { name = await getTokenName(addr); } catch {}
			try { symbol = await getTokenSymbol(addr); } catch {}
			try { ownerAddr = await getTokenOwner(addr); } catch {}

            console.log(name, symbol, ownerAddr, account);
			if (ownerAddr.toLowerCase() === account.toLowerCase()) {
				owned.push({ address: addr, name: name || symbol || 'Unknown', symbol });
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
})();
