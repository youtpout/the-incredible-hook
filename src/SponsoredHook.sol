// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SponsoredHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    // base fee 1.1 %
    uint24 constant baseFee = 11000;
    mapping(address => bool) authorizedRouter;

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

    // todo secure method
    function setWhitelist(address router) external {
        authorizedRouter[router] = true;
    }

    // adjust fee on beforeswap
    function beforeSwap(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookdata
    ) external override returns (bytes4) {
        if (hookdata.length > 0 && authorizedRouter[caller]) {
            // get number of sponsorised swap to apply fee reduction
            uint24 nbSwap = abi.decode(hookdata, (uint24));
            // first swap get bonus of 0.1% and after 0.05% by swap
            if (nbSwap > 0) {
                uint24 fee = baseFee - 1000 - (nbSwap * 500);
                if (fee < 5000) {
                    // min fees of 0.5 %
                    fee = 5000;
                }
                //poolManager.updateDynamicSwapFee(key, fee);
            } else {
               // poolManager.updateDynamicSwapFee(key, baseFee);
            }
        } else {
            // apply base fee if they are 0 sponsored swap
            //poolManager.updateDynamicSwapFee(key, baseFee);
        }
        return BaseHook.beforeSwap.selector;
    }
}
