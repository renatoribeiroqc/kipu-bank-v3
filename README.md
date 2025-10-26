# KipuBank — V3 (USDC Vault with Uniswap v4 Routing)

[Open in Remix](https://remix.ethereum.org/#optimize=true&runs=200)

KipuBankV3 upgrades KipuBankV2 into a USDC‑denominated vault that accepts ETH, USDC, and any ERC‑20 supported by Uniswap v4. Non‑USDC deposits are swapped to USDC inside the contract via the Universal Router, then credited to the user — while enforcing a global bank cap in USDC units and preserving V2’s safety and admin controls.

---

## What’s New vs V2

- USDC‑only Accounting: All balances are held in USDC (6 decimals). The bank cap is enforced on USDC units.
- Universal Router Integration: The contract executes swaps programmatically using Uniswap v4’s Universal Router; ETH and arbitrary ERC‑20 are routed to USDC on deposit.
- Generalized Deposits:
  - `depositUSDC(amount)` — direct credit.
  - `depositETH(commands, inputs, minUsdcOut)` — swap ETH→USDC through the router.
  - `depositArbitraryToken(token, amount, commands, inputs, minUsdcOut)` — pull token, approve router, swap to USDC.
- Policy Preservation: Retains V2’s $1,000 USD‑6 per‑tx withdrawal limit, admin recovery, counters, CEI, and non‑reentrancy.
- Oracle Views: Chainlink price view patterns from V2 can be kept for monitoring/analytics (note: cap enforcement is on USDC units, not oracle quotes).

---

## Contract

- Path: `contracts/KipuBankV3.sol`
- Key immutables:
  - `USDC` — IERC20 (6 decimals)
  - `universalRouter` — IUniversalRouter
  - `permit2` — IPermit2 (optional hook for future permit‑based deposits)
- Core state:
  - `bankCapUsdc6`, `totalUsdc`, `balanceUsdc[user]`
- Core functions:
  - `depositUSDC(uint256 amount)`
  - `depositETH(bytes commands, bytes[] inputs, uint256 minUsdcOut, uint256 deadline)` — generic Universal Router call; encode min‑out in inputs; passes deadline to router
  - `depositArbitraryToken(IERC20 token, uint256 amountIn, bytes commands, bytes[] inputs, uint256 minUsdcOut, uint256 deadline)` — generic router for ERC‑20 with deadline
  - `_swapExactInputSingle(address tokenIn, uint256 amountIn, uint256 minUsdcOut, bytes commands, bytes[] inputs, PoolKey key)` — internal helper using v4 types (`PoolKey`, `Currency`) for validation while executing provided router payload (your `commands/inputs` must include min‑out and will be executed with the external deadline)
  - `withdrawUSDC(uint256 amountUsdc, address to)`
  - `adminRecover(address user, uint256 newUsdc, string reason)`

Router execution is generic: we pass `commands` and `inputs` to the Universal Router and measure USDC delta to credit the user. Typed v4 elements are used via `PoolKey` and `Currency` for validation and clarity. Use the official Uniswap v4 router libraries to encode the correct `Commands/Actions` and inputs; ensure your payload enforces `amountOutMin` for slippage control.

---

## Security and Policy

- Bank Cap: Always enforced on USDC units. On deposit, the contract credits up to `capRemaining()` and refunds any excess USDC to the user.
- Per‑Tx Withdraw Cap: Enforces $1,000 (USD‑6) limit per withdrawal (`USD6_1000`).
- CEI + Reentrancy: Deposits/withdrawals are `nonReentrant` and follow CEI. External calls (router, token transfers) happen after state and custody are in expected order.
- Approvals Hygiene: For ERC‑20 deposits, approval to the router is limited to the exact amount, then reset to zero post‑swap (defensive; optional to save gas).
- Slippage & Pre‑Screen: Users supply `minUsdcOut`. We pre‑check `minUsdcOut <= capRemaining()` to avoid futile execution when the cap is tight.

---

## Deployment

Constructor:

`constructor(address admin, IERC20 usdc, IUniversalRouter router, IPermit2 permit2_, uint256 bankCapUsdc6)`

Suggested testnet addresses (Sepolia/Holesky):
- USDC (testnet): provide the ERC‑20 deployed address you intend to use.
- Universal Router: use the Uniswap v4 router deployment for your network.
- Permit2: optional; can be the official Permit2 address or zero if unused.

Steps (Remix):
1) Compile `contracts/KipuBankV3.sol` (Solidity 0.8.24+, optimizer on, 200 runs).
2) Deploy with the addresses above and an initial `bankCapUsdc6` (e.g., `5_000_000` for $5,000.000).
3) Verify on a block explorer (match compiler + optimizer settings).

---

## Interaction (Testnet)

Direct USDC deposit:
- Approve KipuBankV3 in the USDC token, then call `depositUSDC(amount)`.

ETH / Arbitrary token deposit via Router:
- Prepare Universal Router `commands` and `inputs` encoding an exact‑input route to USDC (single or multi‑hop), including `amountOutMin`.
- For ETH: call `depositETH(commands, inputs, minUsdcOut, deadline)` with `value` set. Contract pre‑screens `minUsdcOut` vs cap, then executes with the given `deadline`.
- For ERC‑20: approve KipuBankV3 to pull `token`, then call `depositArbitraryToken(token, amount, commands, inputs, minUsdcOut, deadline)`.

Withdraw USDC:
- Call `withdrawUSDC(amountUsdc, to)`; respects the $1,000 USD‑6 per‑tx limit and your balance.

Admin:
- `setBankCapUsdc6(newCap)` to adjust the bank cap.
- `adminRecover(user, newUsdc, reason)` to correct balances with coherent totals (auditable event).

---

## Design Notes / Trade‑offs

- Router Encoding: We keep router calls generic to remain aligned with official router libraries on testnet. Use Uniswap’s v4 libraries to build `commands/inputs` and provide a `PoolKey` for typed validation.
- Cap Enforcement on USDC: Unlike V2 which valued deposits via oracles, V3 enforces cap strictly on realized USDC units post‑swap — removing oracle dependency for cap math while still allowing oracle views for UX.
- Approvals: We reset router approval to zero after swaps to reduce long‑lived approvals. This costs extra gas but is safer by default.

---

## Status

- Contract: `contracts/KipuBankV3.sol` (professionally commented, Remix‑friendly)
- UI: V2 demo remains; a V3 UI would need router encoding helpers. Interact directly in Remix or via scripts that prepare Universal Router calls.

---

## License

MIT
