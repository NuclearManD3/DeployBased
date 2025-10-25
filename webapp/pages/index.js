
async function* allTokensGenerator(max = MAX_TOKENS_FETCH) {
	const readProvider = await getReadProvider();
	const factoryAddress = factoryAddresses[currentNetwork];
	if (!factoryAddress) return;

	const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);

	let total = 0;
	try {
		const totalBN = await factory.totalTokens();
		total = Math.min(totalBN.toNumber(), max);
	} catch (err) {
		console.error('Failed to read totalTokens()', err);
		return;
	}

	// iterate in reverse to get newest first
	for (let i = total - 1; i >= 0; i--) {
		try {
			const addr = await factory.tokens(i);
			let name = '', symbol = '', decimals = 18;
			try { name = await getTokenName(addr); } catch {}
			try { symbol = await getTokenSymbol(addr); } catch {}
			try { decimals = await getTokenDecimals(addr); } catch {}
			yield { address: addr, name: name || symbol || 'Unknown', symbol, decimals: Number(decimals) };
		} catch (err) {
			console.warn('Failed to fetch token at index', i, err);
		}
	}
}



(async () => {
	if (!window.signer && window.ethereum) {
		await checkWalletConnection();
	}

	const tokenListElem = document.getElementById('token-list');
	if (!tokenListElem) return;

    await renderList(tokenListElem, allTokensGenerator(), renderTokenCard);

})();

