// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./IERC20.sol";

contract Settler {
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

    error NoRoute();
    error TransferFailed();
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);

    function setRoute(address executor, bytes calldata data) external {
        _routeHeader = RouteHeader(msg.sender, uint64(block.timestamp), uint32(data.length), executor);
        _storeRouteData(data);
    }

    function peek() external view returns (address setter) {
        RouteHeader storage header = _routeHeader;
        if (_isLive(header)) return header.setter;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMin, address recipient)
        external
        returns (uint256 amountOut)
    {
        RouteHeader storage stored = _routeHeader;
        if (!_isLive(stored)) revert NoRoute();
        // Consume and load before any external call, so a reentrant swap or setRoute can't touch this route.
        stored.timestamp = 0;
        RouteHeader memory header = stored;
        bytes memory data = _loadRouteData(header.dataLength);

        _transferFrom(tokenIn, msg.sender, header.executor, amountIn);
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        SANDBOX.run(header.executor, data);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(recipient);
        amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);
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
        (bool success, bytes memory returnData) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || (returnData.length == 0 ? token.code.length == 0 : !abi.decode(returnData, (bool)))) {
            revert TransferFailed();
        }
    }
}

// Calls the executor. It holds no approvals, so setting executor = erc20 can't spend what other callers approved.
contract Sandbox {
    address private immutable SETTLER = msg.sender;

    function run(address executor, bytes calldata data) external {
        // Lets executors rely on msg.sender == SANDBOX meaning "inside swap, tokenIn already delivered".
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
