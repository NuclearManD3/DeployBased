
async function* ownedTokensGenerator(account, factory, max = 20) {
	const BATCH_SIZE = 25;
	const totalBN = await factory.totalTokens();
	const total = Math.min(totalBN.toNumber(), max);

	// Process tokens in batches
	for (let start = 0; start < total; start += BATCH_SIZE) {
		const end = Math.min(start + BATCH_SIZE, total);
		try {
			// Fetch token details in batch
			const tokenDetails = await listManyTokenDetails(start, end);
			for (const detail of tokenDetails) {
				if (detail.owner.toLowerCase() === account.toLowerCase()) {
					yield {
						address: detail.token,
						name: detail.name || detail.symbol || 'Unknown',
						symbol: detail.symbol
					};
				}
			}
		} catch (err) {
			console.warn(`Failed to fetch token details for range ${start} to ${end}:`, err);
			// Continue to next batch on error
		}
	}
}


(async () => {
	if (!account) await connectWallet();

	const myTokenList = document.getElementById('my-token-list');
	if (!myTokenList) return;

	const readProvider = await getReadProvider();
	const factoryAddress = factoryAddresses[currentNetwork];
	if (!factoryAddress) {
		myTokenList.innerHTML = '<div class="token-item">Factory not configured.</div>';
		return;
	}

	const factory = new ethers.Contract(factoryAddress, factoryAbi, readProvider);

	await renderList(
		myTokenList,
		ownedTokensGenerator(account, factory),
		renderTokenCard
	);
})();
