// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract LowFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(uint256 => IPoolManager.SwapParams) public swapRegistered;
    mapping(uint256 => bool) public swapExecuted;
    uint256 lastAdded;
    uint256 lastExecuted;
    uint256 maxIndex;


    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function AddSwap(
        IPoolManager.SwapParams calldata swapParam
    ) external payable {
        ++lastAdded;
        swapRegistered[lastAdded] = swapParam;
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookdata
    ) external override returns (bytes4) {
        if(hookdata.length > 0){
            uint256 nbSwap = abi.decode(hookdata,(uint256));
        }
        return BaseHook.beforeSwap.selector;
    }
}
