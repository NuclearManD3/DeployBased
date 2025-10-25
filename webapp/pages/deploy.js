// Interdependent fields
const startingPrice = document.getElementById('starting-price');
const totalSupply = document.getElementById('total-supply');
const marketCap = document.getElementById('initial-market-cap');
const transitionPrice = document.getElementById('transition-price');
const linearLimit = document.getElementById('liquidity-assistance');
const purchaseInput = document.getElementById('tokens-to-purchase');
const reserveSelect = document.getElementById('reserve-token');

// Initial ratios
let transitionRatio = parseFloat(transitionPrice.value) / parseFloat(startingPrice.value);
let linearRatio = parseFloat(linearLimit.value) / parseFloat(marketCap.value);

// Utility: scale all dependent fields proportionally
function scaleAllFields(scaleFactor, updated) {
	const oldPrice = parseFloat(startingPrice.value);
	const oldCap = parseFloat(marketCap.value);

	const newPrice = oldPrice * scaleFactor;
	const newSupply = (oldCap / newPrice).toFixed(6);

	if (startingPrice != updated) startingPrice.value = newPrice.toFixed(6);
	if (totalSupply != updated) totalSupply.value = newSupply;

	const newCap = (newPrice * newSupply).toFixed(2);
	if (marketCap != updated) marketCap.value = newCap;

	transitionPrice.value = (newPrice * transitionRatio).toFixed(6);
	linearLimit.value = (newCap * linearRatio).toFixed(0);
}

// Event listeners
startingPrice.addEventListener('input', () => {
	const oldPrice = parseFloat(startingPrice.dataset.prev || startingPrice.value);
	const newPrice = parseFloat(startingPrice.value);
	if (!isNaN(oldPrice) && !isNaN(newPrice)) {
		scaleAllFields(newPrice / oldPrice, startingPrice);
		startingPrice.dataset.prev = newPrice;
	}
});

totalSupply.addEventListener('input', () => {
	const oldSupply = parseFloat(totalSupply.dataset.prev || totalSupply.value);
	const newSupply = parseFloat(totalSupply.value);
	if (!isNaN(oldSupply) && !isNaN(newSupply)) {
		scaleAllFields(newSupply / oldSupply, totalSupply);
		totalSupply.dataset.prev = newSupply;
	}
});

marketCap.addEventListener('input', () => {
	const oldCap = parseFloat(marketCap.dataset.prev || marketCap.value);
	const newCap = parseFloat(marketCap.value);
	if (!isNaN(oldCap) && !isNaN(newCap)) {
		scaleAllFields(newCap / oldCap, marketCap);
		marketCap.dataset.prev = newCap;
	}
});

transitionPrice.addEventListener('input', () => {
	const price = parseFloat(startingPrice.value);
	const trans = parseFloat(transitionPrice.value);
	if (!isNaN(price) && !isNaN(trans)) transitionRatio = trans / price;
});

linearLimit.addEventListener('input', () => {
	const cap = parseFloat(marketCap.value);
	const liq = parseFloat(linearLimit.value);
	if (!isNaN(cap) && !isNaN(liq)) linearRatio = liq / cap;
});

// Initialize prev values
startingPrice.dataset.prev = startingPrice.value;
totalSupply.dataset.prev = totalSupply.value;
marketCap.dataset.prev = marketCap.value;

// Reserve token change
reserveSelect.addEventListener('change', (e) => {
	linearLimit.value = e.target.value === 'WETH' ? '2' : '10000';
});

// Purchase slider
purchaseInput.addEventListener('input', (e) => {
	document.getElementById('tokens-to-purchase-value').innerText = `${e.target.value}%`;
});

// Deploy form submission
document.getElementById('deploy-form').addEventListener('submit', async (e) => {
	e.preventDefault();
	if (!signer) return showError('Connect wallet first');
	showSpinner(true);

	try {
		const name = document.getElementById('token-name').value;
		const symbol = document.getElementById('token-symbol').value;
		const decimals = parseInt(document.getElementById('decimals').value);
		const totalSupplyBN = ethers.utils.parseUnits(totalSupply.value, decimals);

		const startPriceRaw = parseFloat(startingPrice.value);
		const switchPriceRaw = parseFloat(transitionPrice.value);

		const reserveSymbol = reserveSelect.value;
		const reserveAddress = tokenAddresses[currentNetwork + reserveSymbol];
		const reserveDecimals = tokenDecimals[currentNetwork + reserveSymbol];

		const curveLimit = ethers.utils.parseUnits(linearLimit.value, reserveDecimals);
		const tokensToPurchasePercent = parseFloat(purchaseInput.value);
		const fee = 10000;
		const amountToPurchase = totalSupplyBN.mul(Math.floor(tokensToPurchasePercent * 100)).div(10000);

		const toRawPrice = (price, launchDecimals, reserveDecimals) =>
			ethers.BigNumber.from(Math.floor(price * 10 ** reserveDecimals))
				.mul(ethers.BigNumber.from(2).pow(128))
				.div(ethers.BigNumber.from(10).pow(launchDecimals));

		const startPrice = toRawPrice(startPriceRaw, decimals, reserveDecimals);
		const switchPrice = toRawPrice(switchPriceRaw, decimals, reserveDecimals);

		const twoPow128 = ethers.BigNumber.from(2).pow(128);
		const dy = twoPow128.mul(curveLimit).div(startPrice.add(switchPrice));
		const y1 = totalSupplyBN.sub(dy);
		const reserveOffset = switchPrice.mul(y1).div(twoPow128).sub(curveLimit);

		const factoryAddress = factoryAddresses[currentNetwork];
		if (!factoryAddress) throw new Error('Factory not configured for this network');

		const factory = new ethers.Contract(factoryAddress, factoryAbi, signer);

		const tx = await factory.launchToken(
			name,
			symbol,
			decimals,
			reserveAddress,
			fee,
			startPrice,
			switchPrice,
			curveLimit,
			reserveOffset,
			totalSupplyBN
		);

		const receipt = await tx.wait();
		const tokenCreatedEvent = receipt.events.find(e => e.event === 'TokenCreated');
		const tokenAddr = tokenCreatedEvent?.args?.token;

		if (tokenAddr) window.location.href = `token.html?address=${tokenAddr}`;
		else showError('TokenCreated event not found');
	} catch (err) {
		showError(err.message);
	} finally {
		showSpinner(false);
	}
});
