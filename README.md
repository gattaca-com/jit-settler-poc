# JIT Settler (PoC)

A contract that lets a block builder plug a better route into a swap, just in time, inside the block it builds.

## Assumptions and guarantees

Integrators only accept routes from builders (`setters`) they trust not to waste their gas. That trust does not extend to their funds. A route can't take anything the caller didn't send, and the caller still fully enforces its own `amountOutMin`. If a route pays less, the swap reverts and the caller falls back to its own route. What an accepted builder does guarantee is that it never includes a caller's transaction in a block with a route set unless the caller's entire transaction succeeded in its simulation with that route.

## How it works

1. While building a block, the builder finds a better route for an upcoming swap and posts it right before that transaction.
2. The integrator checks who posted the route. If it's a builder it accepts, it tries the route.
3. If the route pays at least `amountOutMin`, the swap goes through. Otherwise it reverts and the integrator uses its own route.
4. Importantly, the builder already checks step 3 while building the block. If the route doesn't pay enough or doesn't satisfy the caller, the builder doesn't set it, and it never lands on chain.

A route only lives for one swap, in the block it was posted in.

This is a proof of concept and has not been audited.

## Strengths

- **Open to any builder.** Anyone can post a route, with no keys or registry. Integrators integrate once and decide for themselves which builders they accept.
- **Any executor.** A route is just a contract address and calldata. Each builder brings its own contract and venues, and adding a venue never means redeploying anything shared.
- **No fee logic.** The contract has no fees or treasury. Builders make sure they are paid during simulation.
- **One route, used once.** A route is used by a single swap and is gone after it. Nothing is keyed or hashed, so there are no slot collisions, and a route never lingers into later blocks.
- **The caller's own floor.** `amountOutMin` is checked inside the swap, so a plain `try`/`catch` gives a clean fallback. Nothing relies on the builder's word.
- **Small trust surface.** The contract holds no funds, has no owner and can't be upgraded. Routes run from a sandbox that holds no approvals, so approving the settler is safe.
- **No external dependencies.** No registry and no signatures. Posting a route is a single transaction.

## Build

```sh
forge build
```
