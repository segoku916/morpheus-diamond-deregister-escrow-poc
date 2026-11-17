# Morpheus — ProviderRegistry deregister locks direct-session user escrow (PoC)

Foundry proof of concept for a Morpheus bug bounty report. `providerDeregister`
guards only on active bids, never open sessions. When a provider exits
mid-session, the session still closes: `_rewardUserAfterClose` charges the user
the FULL provider rewards (SessionRouter.sol:300) while `_claimForProvider`
caps payout at `stake − limitPeriodEarned` = 0 after deregister (L383-385).
The difference stays in the diamond with no recovery path (it is not
`feeBalance`, and there is no sweep). No malice is required — an ordinary
provider exit triggers it. Stipend sessions are NOT affected.

- **Target:** LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
  (Base, Appendix A; ProviderRegistry + SessionRouter facets)
- **Fork:** Base mainnet, pinned to block **58647015**
- **Result:** 0.292 MOR locked in the PoC session; max 6,048 MOR (~$4,264 at
  $0.7058/MOR) per session for a 7-day max-price (0.01 MOR/s) session. No
  privileged accounts are used.

## Run (one command, from a clean clone)

```sh
forge test
```

Requires [Foundry](https://getfoundry.sh/) (forge 1.9+). `forge-std` is vendored
under `lib/`, so no install step is needed. The fork RPC is
`https://mainnet.base.org`.

## What the tests assert

- `testDeregisterWithOpenDirectSessionLocksUserEscrow` — provider registers,
  posts a bid, user opens a direct-payment session; provider deletes the bid
  and deregisters mid-session (no open-session check) and withdraws the full
  stake. After close, the provider receives 0 (`providerWithdrawnAmount == 0`,
  `claimForProvider` pays 0), yet the user loses exactly the provider rewards
  and the diamond keeps them.
- `testControlProviderStaysRegistered` — control: with no deregister, the
  registered provider is paid in full and the diamond keeps nothing extra.
