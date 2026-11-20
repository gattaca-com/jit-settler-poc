# JIT Settler (PoC)

A contract that lets a block builder plug a better route into a swap, just in time, inside the block it builds.

## Assumptions and guarantees

Integrators only accept routes from builders (`setters`) they trust not to waste their gas. That trust does not extend to their funds. A route can't take anything the caller didn't send, and the caller still fully enforces its own `amountOutMin`. If a route pays less, the swap reverts and the caller falls back to its own route. What an accepted builder does guarantee is that it never includes a caller's transaction in a block with a route set unless the caller's entire transaction succeeded and the call to `swap` was not reverted in its simulation with that route.

## How it works

1. While building a block, the builder finds a better route for an upcoming swap and posts it right before that transaction.
2. The integrator calls `swap(req, callback)`. With `callback` set and a route live, the settler calls back `routeAvailable(setter)` on the integrator. If it accepts that builder, it returns its floor. Otherwise it reverts. Without `callback`, the integrator checks the setter with `peek(req)` beforehand.
3. If the route pays at least the floor (the callback's return with `callback`, else `req.amountOutMin`), the swap goes through. Otherwise it reverts, and so does `swap` when there's no route or the integrator declined. In every case the integrator falls back to its own route.
4. Importantly, the builder already checks step 3 while building the block. If the route doesn't pay enough or doesn't satisfy the caller, the builder doesn't set it, and it never lands on chain.

A route only lives for one swap, in the block it was posted in.

This is a proof of concept and has not been audited.

## Strengths

- **Open to any builder.** Anyone can post a route, with no keys or registry. Integrators integrate once and decide for themselves which builders they accept.
- **Any executor.** A route is just a contract address and calldata. Each builder brings its own contract and venues, and adding a venue never means redeploying anything shared.
- **No fee logic.** The contract has no fees or treasury. Builders make sure they are paid during simulation.
- **One route, used once.** A route is used by a single swap and is gone after it. Nothing is keyed or hashed, so there are no slot collisions, and a route never lingers into later blocks.
- **Simple integration.** Integrators pass their request to `peek` or `swap`, so builders always see it in simulation. The callback is optional.
- **Venues can see JIT flow.** While a route runs, `currentRoute()` returns its setter and the caller of `swap`, so a venue can quote tighter for builders it trusts. The router's address alone can't show this, since anyone can post a route through any router.
- **The caller's own floor.** `amountOutMin` is part of the request. With the callback, the integrator instead sets it only once it knows a route is live, for example after pricing its own route. `swap` checks it, so a plain `try`/`catch` gives a clean fallback. Nothing relies on the builder's word.
- **Small trust surface.** The contract holds no funds, has no owner and can't be upgraded. Routes run from a sandbox that holds no approvals, so approving the settler is safe.
- **No external dependencies.** No registry and no signatures. Posting a route is a single transaction.

## Integrating

- Pass your request to `peek` or `swap` even when no route is live. That's how builders see it.
- With `callback`, implement `ISettlerCaller.routeAvailable`. Check that `msg.sender` is the settler and that the setter is a builder you accept, then return your floor to take the route or revert to decline it. Don't put it behind a reentrancy guard. It is called while your own call to `swap` is still running, so a guard makes it revert and every route is silently declined.
- Without `callback`, call `peek(req)` first and call `swap` only if it returns a builder you accept.
- Call `swap` in a `try`/`catch` with a gas cap, and run your own route on any revert. The route gets all the gas the call has.
- Approve the settler for `amountIn` of `tokenIn`. With the callback, doing it inside `routeAvailable` leaves no allowance behind when no route runs.
- Optionally call `reportDefault(req, amountOut)` after running your own route.

## Build

```sh
forge build
```
