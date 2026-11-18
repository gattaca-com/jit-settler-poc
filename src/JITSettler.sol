// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "./IERC20.sol";

interface ISettlerCaller {
    /// @notice Called by `swap` when a route is live. Return the least `recipient` must receive to
    ///         run it, or revert to decline it and run your default route instead.
    function routeAvailable(address setter) external returns (uint256 amountOutMin);
}

/// @title JITSettler
/// @notice flashbots/JITSettler (4f99161) with a callback instead of `peek`. Callers always call
///         `swap`, which asks them through `ISettlerCaller.routeAvailable` whether to run a live
///         route, and returns the outcome either way.
contract JITSettler {
    enum Outcome {
        NO_ROUTE,
        ROUTE_DECLINED,
        EXECUTED
    }

    struct RouteHeader {
        address setter;
        uint64 timestamp;
        uint32 dataLength;
        address executor;
    }

    // Words past dataLength are stale but ignored, and rewriting non-zero slots is cheap.
    uint256 private constant _ROUTE_DATA_SLOT = uint256(keccak256("Settler.route.data"));

    Sandbox public immutable SANDBOX = new Sandbox();

    RouteHeader private _routeHeader;

    /// @notice Emitted when a swap fills through a posted route. `caller` called `swap`.
    event JITRoutedV1(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );

    error TransferFailed();
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);

    /// @notice Posts the route for this block. The setter is msg.sender. A builder can post
    ///         through its own contract, so it can rotate keys without callers changing the
    ///         setters they trust.
    function setRoute(address executor, bytes calldata data) external {
        _routeHeader =
            RouteHeader(msg.sender, uint64(block.timestamp), uint32(data.length), executor);
        _storeRouteData(data);
    }

    /// @param gasLimit The most gas the route's executor gets, so a route cannot use up the gas
    ///        the caller needs for its default route. Builders fit routes under it.
    /// @return outcome Whether the route ran. Unless `EXECUTED`, run your default route.
    /// @return amountOut What `recipient` received if `EXECUTED`, else 0.
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 gasLimit
    ) external returns (Outcome outcome, uint256 amountOut) {
        RouteHeader storage stored = _routeHeader;
        if (!_isLive(stored)) return (Outcome.NO_ROUTE, 0);
        // Consume and load before any external call, so a reentrant swap or setRoute can't touch
        // this route.
        stored.timestamp = 0;
        RouteHeader memory header = stored;
        bytes memory data = _loadRouteData(header.dataLength);

        uint256 amountOutMin;
        try ISettlerCaller(msg.sender).routeAvailable(header.setter) returns (uint256 min) {
            amountOutMin = min;
        } catch {
            return (Outcome.ROUTE_DECLINED, 0);
        }

        _transferFrom(tokenIn, msg.sender, header.executor, amountIn);
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        SANDBOX.run{ gas: gasLimit }(header.executor, data);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(recipient);
        amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        emit JITRoutedV1(
            msg.sender, tokenIn, tokenOut, recipient, amountIn, amountOutMin, amountOut
        );
        return (Outcome.EXECUTED, amountOut);
    }

    function _isLive(RouteHeader storage header) private view returns (bool) {
        return header.timestamp == block.timestamp;
    }

    function _storeRouteData(bytes calldata data) private {
        uint256 slot = _ROUTE_DATA_SLOT;
        assembly ("memory-safe") {
            for { let offset := 0 } lt(offset, data.length) { offset := add(offset, 0x20) } {
                sstore(add(slot, shr(5, offset)), calldataload(add(data.offset, offset)))
            }
        }
    }

    function _loadRouteData(uint256 length) private view returns (bytes memory data) {
        uint256 slot = _ROUTE_DATA_SLOT;
        assembly ("memory-safe") {
            data := mload(0x40)
            mstore(data, length)
            let start := add(data, 0x20)
            for { let offset := 0 } lt(offset, length) { offset := add(offset, 0x20) } {
                mstore(add(start, offset), sload(add(slot, shr(5, offset))))
            }
            mstore(0x40, add(start, and(add(length, 31), not(31))))
        }
    }

    // Empty returndata counts as success (USDT-style), but only if the token has code.
    function _transferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (
            !success
                || (returnData.length == 0
                        ? token.code.length == 0
                        : !abi.decode(returnData, (bool)))
        ) {
            revert TransferFailed();
        }
    }
}

// Calls the executor. It holds no approvals, so setting executor = erc20 can't spend what other
// callers approved.
contract Sandbox {
    address private immutable SETTLER = msg.sender;

    function run(address executor, bytes calldata data) external {
        // Lets executors rely on msg.sender == SANDBOX meaning "inside swap, tokenIn already
        // delivered".
        if (msg.sender != SETTLER) revert();
        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, data.offset, data.length)
            if iszero(call(gas(), executor, 0, input, data.length, 0, 0)) {
                returndatacopy(input, 0, returndatasize())
                revert(input, returndatasize())
            }
        }
    }
}
