// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {SponsoredHook} from "../src/SponsoredHook.sol";
import {CustomRouter} from "../src/CustomRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IPermit2, ISignatureTransfer} from "permit2/src/interfaces/IPermit2.sol";

contract SponsoredTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SponsoredHook hook;
    CustomRouter router;
    PoolId poolId;
    address permit2;

    struct PermitInfo {
        address token;
        address owner;
        bool zeroForOne;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        permit2 = deployPermit2();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SponsoredHook).creationCode,
            abi.encode(address(manager))
        );
        hook = new SponsoredHook{salt: salt}(IPoolManager(address(manager)));
        require(
            address(hook) == hookAddress,
            "SponsoredTest: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(currency0, currency1, 11000, 60, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                10 ether
            ),
            ZERO_BYTES
        );

        // add router and whitelist it
        //router = new CustomRouter(Currency.unwrap(currency0),Currency.unwrap(currency1), permit2);
        hook.setWhitelist(address(this));

         //MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
         //MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function testSwap() public {
        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = 200; 
        customSwap(key,amountSpecified,zeroForOne,ZERO_BYTES);
    }

    function testLiquidityHooks() private {
        // remove liquidity
        int256 liquidityDelta = -1e18;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, liquidityDelta),
            ZERO_BYTES
        );
    }


    /// @notice Swap tokens
    /// @param key the pool where the swap is happening
    /// @param amountSpecified the amount of tokens to swap
    /// @param zeroForOne whether the swap is token0 -> token1 or token1 -> token0
    /// @param permitInfos permit2 signature sponsored swap
    function customSwap(
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne,
        bytes memory permitInfos
    ) internal {

        IPermit2 PERMIT2 = IPermit2(permit2);
        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            });

        bytes memory hookData = ZERO_BYTES;
        uint24 swappedIndex = 0;
        if (permitInfos.length > 0) {
            PermitInfo[] memory infos = abi.decode(permitInfos, (PermitInfo[]));
            for (uint i = 0; i < infos.length; i++) {
                PermitInfo memory data = infos[i];
                if (data.deadline < block.timestamp) {
                    continue;
                }
                PERMIT2.permitTransferFrom(
                    // The permit message.
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({
                            token: data.token,
                            amount: data.amount
                        }),
                        nonce: data.nonce,
                        deadline: data.deadline
                    }),
                    // The transfer recipient and amount.
                    ISignatureTransfer.SignatureTransferDetails({
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
                IPoolManager.SwapParams memory paramsPermit = IPoolManager
                    .SwapParams({
                        zeroForOne: data.zeroForOne,
                        amountSpecified: int256(data.amount),
                        sqrtPriceLimitX96: data.zeroForOne
                            ? MIN_PRICE_LIMIT
                            : MAX_PRICE_LIMIT // unlimited impact
                    });

                swapRouter.swap(key, paramsPermit, testSettings, hookData);
                ++swappedIndex;
            }
            hookData = abi.encode(swappedIndex);
        }
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        swapRouter.swap(key, params, testSettings, hookData);
    }
}
