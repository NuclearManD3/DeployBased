
async function* allTokensGenerator(max = 20) {
	const BATCH_SIZE = 25;
	const readProvider = await getReadProvider();
	const factoryAddress = factoryAddresses[currentNetwork];
	if (!factoryAddress) {
		console.error('Factory address not found for current network');
		return;
	}

	const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);

	let total = 0;
	try {
		const totalBN = await factory.totalTokens();
		total = Math.min(totalBN.toNumber(), max);
	} catch (err) {
		console.error('Failed to read totalTokens():', err);
		return;
	}

	// Process tokens in reverse order, in batches
	for (let end = total; end > 0; end -= BATCH_SIZE) {
		const start = Math.max(end - BATCH_SIZE, 0);
		try {
			// Fetch token details in batch
			const tokenDetails = await listManyTokenDetails(start, end);
			// Yield in reverse order within the batch
			for (let i = tokenDetails.length - 1; i >= 0; i--) {
				const detail = tokenDetails[i];
				let decimals = 18; // Default value
				try {
					decimals = await getTokenDecimals(detail.token);
				} catch {}
				yield {
					address: detail.token,
					name: detail.name || detail.symbol || 'Unknown',
					symbol: detail.symbol,
					decimals: Number(decimals)
				};
			}
		} catch (err) {
			console.warn(`Failed to fetch token details for range ${start} to ${end}:`, err);
			// Continue to next batch on error
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

