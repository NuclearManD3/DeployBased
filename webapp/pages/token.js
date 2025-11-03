
const tokenNameElem = document.getElementById('token-name');
const tokenDetailsElem = document.getElementById('token-details');

async function refreshPageDetails() {
	const swapAmountIn = document.getElementById('swap-amount-in');
	const swapAmountOut = document.getElementById('swap-amount-out');
	const swapTokenIn = document.getElementById('swap-token-in');
	const swapTokenOut = document.getElementById('swap-token-out');
	const swapButton = document.getElementById('swap-button');
	const swapStatus = document.getElementById('swap-status');
	const swapDirectionBtn = document.getElementById('swap-direction');

	const tokenAddress = new URLSearchParams(window.location.search).get('address');
	const tokenName = await getTokenName(tokenAddress);

	const defaultTokens = [
		{ address: tokenAddress, label: tokenName },
		{ address: usdcAddress(), label: 'USDC' }
	];

	let poolAddress = null;

	// Helper: populate a select with token options
	function populateDropdown(selectEl, tokens, selectedAddr) {
		selectEl.innerHTML = '';
		tokens.forEach(t => {
			const opt = document.createElement('option');
			opt.value = t.address;
			opt.text = t.label;
			if (t.address.toLowerCase() === selectedAddr?.toLowerCase()) {
				opt.selected = true;
			}
			selectEl.appendChild(opt);
		});
	}

	// Initialize both dropdowns with all tokens
	populateDropdown(swapTokenIn, defaultTokens, tokenAddress);
	populateDropdown(swapTokenOut, defaultTokens, defaultTokens[1].address);

	// Allow pasting arbitrary addresses
	function addTokenIfMissing(selectEl, addr) {
		addr = addr.trim();
		if (!addr) return;
		if (![...selectEl.options].some(o => o.value.toLowerCase() === addr.toLowerCase())) {
			const opt = document.createElement('option');
			opt.value = addr;
			opt.text = addr.slice(0,6) + '...' + addr.slice(-4);
			selectEl.appendChild(opt);
		}
	}

	swapTokenIn.addEventListener('change', () => addTokenIfMissing(swapTokenIn, swapTokenIn.value));
	swapTokenOut.addEventListener('change', () => addTokenIfMissing(swapTokenOut, swapTokenOut.value));

	await checkWalletConnection();

	poolAddress = await findPoolForTokens(tokenAddress, usdcAddress());
	console.log(tokenAddress, usdcAddress(), poolAddress);

	async function refreshTokenData() {
		showSpinner(true);

		const currentPrice = await getCurrentPrice(poolAddress);

		try {
			const [symbol, decimals, totalSupply, ownerAddr, description] = await Promise.all([
				getTokenSymbol(tokenAddress),
				getTokenDecimals(tokenAddress),
				getTokenSupply(tokenAddress),
				getTokenOwner(tokenAddress),
				getTokenDescription(tokenAddress)
			]);

			tokenNameElem.innerText = `${tokenName}`;
			tokenDetailsElem.innerHTML = `
				<p><strong>Symbol:</strong> ${symbol}</p>
				<p><strong>Price:</strong> $${currentPrice}
				<p><strong>Total Supply:</strong> ${totalSupply}</p>
				<p>${description}</p>
				<p><strong>Decimals:</strong> ${decimals}</p>
				${makeAddressHTML('Address', tokenAddress, "/token/")}
				${makeAddressHTML('Owner', ownerAddr)}
			`;

			document.querySelectorAll('.copy-btn').forEach(btn => {
				btn.addEventListener('click', async () => {
					try {
						await navigator.clipboard.writeText(btn.dataset.addr);
						btn.innerText = '✓';
						setTimeout(() => { btn.innerText = 'Copy'; }, 1000);
					} catch {}
				});
			});

			// Draw the chart
			reserves = await getPoolReserves(poolAddress);
			curve = await getPoolCurve(poolAddress);
			createPoolPriceWidget('chart-container', {
				totalSupply: await getTokenSupply(tokenAddress),
				tokenPriceUSD: currentPrice,
				currentPrice: currentPrice,
				currentInvestment: reserves.reserve,
				p0: curve.basePrice,
				curveLimit: curve.curveLimit,
				M: curve.multiple,
				b: curve.reserveOffset
			});

		} catch (err) {
			console.error('Error loading token:', err);
			tokenNameElem.innerText = 'Error';
			tokenDetailsElem.innerHTML = 'Could not fetch token info.';
		} finally {
			showSpinner(false);
		}
	}

	tokenNameElem.innerText = 'Loading...';
	tokenDetailsElem.innerHTML = '';

	refreshTokenData();

	// If user is pool owner, add fee collection button
	try {
		const owner = await getPoolOwner(poolAddress);
		if (owner && account && owner.toLowerCase() === account.toLowerCase()) {
			const collectBtn = document.createElement('button');
			collectBtn.innerText = 'Collect Fees';
			collectBtn.id = 'collect-fees';
			collectBtn.addEventListener('click', async () => {
				swapStatus.innerText = 'Collecting fees...';
				try {
					const tx = await collectFees(
						signer,
						poolAddress,
						account,
						-887272,
						887272,
						0x80000000000000000000000000000000n,
						0x80000000000000000000000000000000n
					);
					swapStatus.innerText = 'Fees collected!';
				} catch (err) {
					swapStatus.innerText = 'Fee collection failed: ' + err.message.split("(", 1)[0];
				}
			});
			document.getElementById('token-details').insertAdjacentElement('afterend', collectBtn);
		}
	} catch (err) {
		console.warn('Owner check failed:', err);
	}

	// Debounced output estimation
	let debounceTimer;
	function debouncedEstimate() {
		clearTimeout(debounceTimer);
		debounceTimer = setTimeout(estimateOut, 500);
	}

	async function estimateOut() {
		const inAddr = swapTokenIn.value;
		const outAddr = swapTokenOut.value;
		const amountIn = parseFloat(swapAmountIn.value);
		if (!inAddr || !outAddr || isNaN(amountIn) || amountIn <= 0) {
			swapAmountOut.value = '';
			return;
		}

		try {
			const decimalsIn = await getTokenDecimals(inAddr);
			const decimalsOut = await getTokenDecimals(outAddr);
			const amountInRaw = ethers.utils.parseUnits(amountIn.toString(), decimalsIn);
			const { poolAddress, zeroForOne, tokensIn, tokensOut } = await estimateSwap(signer, inAddr, outAddr, amountInRaw);
			swapAmountIn.value = ethers.utils.formatUnits(tokensIn, decimalsIn);
			swapAmountOut.value = ethers.utils.formatUnits(tokensOut, decimalsOut);
		} catch (err) {
			swapAmountOut.value = '';
			console.error(err);
		}
	}

	// Swap direction: switch selections and values, **keep options**
	swapDirectionBtn.addEventListener('click', () => {
		// Swap values
		const tempAmount = swapAmountIn.value;
		swapAmountIn.value = swapAmountOut.value;
		swapAmountOut.value = tempAmount;

		// Swap selected addresses
		const tempAddr = swapTokenIn.value;
		swapTokenIn.value = swapTokenOut.value;
		swapTokenOut.value = tempAddr;

		// Swap labels in dropdown if user added custom tokens
		const tempOptions = [...swapTokenIn.options].map(o => ({ value: o.value, text: o.text }));
		populateDropdown(swapTokenIn, [...swapTokenOut.options].map(o => ({ address: o.value, label: o.text })), swapTokenIn.value);
		populateDropdown(swapTokenOut, tempOptions.map(o => ({ address: o.value, label: o.text })), swapTokenOut.value);

		debouncedEstimate();
	});

	// Event listeners
	swapAmountIn.addEventListener('input', debouncedEstimate);
	swapTokenIn.addEventListener('change', debouncedEstimate);
	swapTokenOut.addEventListener('change', debouncedEstimate);

	swapButton.addEventListener('click', async () => {
		const inAddr = swapTokenIn.value;
		const outAddr = swapTokenOut.value;
		const amountIn = parseFloat(swapAmountIn.value);
		const amountOut = parseFloat(swapAmountOut.value);
		if (!signer || !inAddr || !outAddr || isNaN(amountIn) || amountIn <= 0) {
			alert('Fill in valid amount and connect wallet.');
			return;
		}

		swapButton.disabled = true;
		swapStatus.innerText = 'Swapping...';
		try {
			const decimalsIn = await getTokenDecimals(inAddr);
			const decimalsOut = await getTokenDecimals(outAddr);
			const amountInRaw = ethers.utils.parseUnits(amountIn.toString(), decimalsIn);
			const amountOutMin = ethers.utils.parseUnits(amountOut.toString(), decimalsOut);
			const tx = await executeSwap(signer, inAddr, outAddr, amountInRaw, amountOutMin, true);
			swapStatus.innerText = 'Swap successful!';
			swapAmountIn.value = '';
			swapAmountOut.value = '';
		} catch (err) {
			swapStatus.innerText = 'Swap failed: ' + err.message.split("(", 1)[0];
			console.error(err);
		} finally {
			swapButton.disabled = false;
		}
		await refreshTokenData();
	});

}
