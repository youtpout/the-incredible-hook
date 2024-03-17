// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPermit2, IERC20} from "./interfaces/IPermit2.sol";

contract CustomRouter {
    struct PermitInfo {
        IERC20 token;
        address owner;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    PoolSwapTest swapRouter;
    address public immutable poolKey;
    IPermit2 public immutable PERMIT2;

    // slippage tolerance to allow for unlimited price impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;
    bytes constant ZERO_BYTES = new bytes(0);

    constructor(address manager, IPermit2 permit_) {
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        PERMIT2 = permit_;
    }

    /// @notice Swap tokens
    /// @param key the pool where the swap is happening
    /// @param amountSpecified the amount of tokens to swap
    /// @param zeroForOne whether the swap is token0 -> token1 or token1 -> token0
    /// @param permitInfos permit2 signature sponsored swap
    function swap(
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne,
        bytes calldata permitInfos
    ) public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            });

        bytes memory hookData = ZERO_BYTES;
        if (permitInfos.length > 0) {
            PermitInfo[] memory infos = abi.decode(permitInfos, (PermitInfo[]));
            for (uint i = 0; i < infos.length; i++) {
                PermitInfo memory data = infos[i];
                PERMIT2.permitTransferFrom(
                    // The permit message.
                    IPermit2.PermitTransferFrom({
                        permitted: IPermit2.TokenPermissions({
                            token: data.token,
                            amount: data.amount
                        }),
                        nonce: data.nonce,
                        deadline: data.deadline
                    }),
                    // The transfer recipient and amount.
                    IPermit2.SignatureTransferDetails({
                        to: address(this),
                        requestedAmount: data.amount
                    }),
                    // The owner of the tokens, which must also be
                    // the signer of the message, otherwise this call
                    // will fail.
                    data.owner,
                    // The packed signature that was the result of signing
                    // the EIP712 hash of `permit`.
                    data.signature
                );
            }
            hookData = abi.encode(uint24(infos.length));
        }
        swapRouter.swap(key, params, testSettings, hookData);
    }
}
