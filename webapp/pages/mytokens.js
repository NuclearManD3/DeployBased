
async function* ownedTokensGenerator(account, factory, max = MAX_TOKENS_FETCH) {
	const totalBN = await factory.totalTokens();
	const total = Math.min(totalBN.toNumber(), max);

	for (let i = 0; i < total; i++) {
		const addr = await factory.tokens(i);
		let name = '', symbol = '', ownerAddr = '';
		try { name = await getTokenName(addr); } catch {}
		try { symbol = await getTokenSymbol(addr); } catch {}
		try { ownerAddr = await getTokenOwner(addr); } catch {}

		if (ownerAddr.toLowerCase() === account.toLowerCase()) {
			yield { address: addr, name: name || symbol || 'Unknown', symbol };
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
