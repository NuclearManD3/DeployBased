
# Deploy: Based

This platform allows users to easily:
- Launch new tokens
- Ensure tokens launched on the platform are secure
- Create fair launch and liquidity pools automatically
- Inscentivize liquidity pool usage with emissions

Emissions are given in Deploy tokens, which are backed by USD in lending protocols to earn yield.
By earning yield, the Deploy tokens can pay for liquidity pool emissions and help fund protocol development.
This also ensures the tokens are backed with real value, to prevent depreciation.

Any token launched will be lauched with one FairLaunch pool, which protects the users from malice
and manipulation, and one Uniswap pool, to encourage adoption.  A token launcher is required to
deposit Eth for initial liquidity, and receives part of the initial supply in relation to the
initial Eth provided and the initial market cap.


## Tokenomics: Flow of Deploy tokens

Requirements:
1. Non-inflationary: constant supply
2. Yield earned inside the contract to help boost pools
3. Purchases of the token help fund the yield-bearing reserves
4. Token is not pegged to yield-bearing assets
5. Tokens are routed to a contract for inscentivizing pool liquidity

Thus, the token contract must hold all supply at initialization, and distribute the supply when:
1. The token is purchased, with the price based on multiple factors
2. Yield is earned, with half of the tokens going to the inscentivizing contract and half to the revenue/fee contract
3. ???

On the other hand, the contract must absorb tokens under some conditions:
1. Sale of tokens
2. A new token is deployed (this costs Deploy tokens)

To prevent pegging to the yield-bearing assets, the buy and sell price should be affected by other factors:
1. Ratio of assets held by the contract - the goal is 15% held, so prices will move to inscentivize
   buying or selling to maintain this
2. Yield-bearing asset amounts - more increases price
3. Discount when selling tokens according to appreciation of assets held, so that the protocol keeps most
   of the yield, passing on some to holders

## FairLaunch Pool Behavior

A FairLaunch pool will start at a minimum token price, starting with a largely linear price change as
people buy, and transition to a curve more like xy = k as supply dwindles.  This pool charges a 1% fee,
0.2% of which goes to the token creator, 0.6% of which goes to the liquidity providers, and 0.2% goes
to the protocol.

A FairLaunch pool may use WETH, USDC, or USDS.  In all cases the WETH, USDC, or USDS is put up in a lending
protocol to earn yield, which reflects as extra fees on top of the swapping fees.


