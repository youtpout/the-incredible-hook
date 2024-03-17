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
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

contract SponsoredTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SignatureVerification for bytes;
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

    address alice;
    uint256 alicekey;
    bytes32 DOMAIN_SEPARATOR;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (alice, alicekey) = makeAddrAndKey("alice");
        permit2 = deployPermit2();
        DOMAIN_SEPARATOR = IPermit2(permit2).DOMAIN_SEPARATOR();

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
        (key, poolId) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(hook)),
            SwapFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_RATIO_1_1,
            ZERO_BYTES
        );

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
        hook.setWhitelist(address(swapRouter));

        //MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        //MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function testSwap() public {
        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = 200;
        customSwap(key, amountSpecified, zeroForOne, 0);
        (,,,uint24 fee) = manager.getSlot0(poolId);
        assertEq(fee,11000);
    }

    function testSponsoredSwap() public {
        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = 500;
        customSwap(key, amountSpecified, zeroForOne, 1);
        vm.stopPrank();
        (,,,uint24 fee) = manager.getSlot0(poolId);
         assertEq(fee,10000);
    }

    function testSponsoredSwapPermit() public {
       uint256 nonce = 0;
       uint256 deadline  = block.timestamp + 100;
       uint256 amount = 0;
       address token0 = Currency.unwrap(currency0);
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(token0, nonce,amount, deadline);
        bytes memory sig = getPermitTransferSignature(permit, alicekey, DOMAIN_SEPARATOR);

        PermitInfo memory info = PermitInfo(token0,alice,true,amount,nonce,deadline,sig);
        PermitInfo[] memory infos = new PermitInfo[](1);
        infos[0] = info;

        bool zeroForOne = true;
        int256 amountSpecified = 500;
        customSwapSigned(key, amountSpecified, zeroForOne, abi.encode(infos));
        (,,,uint24 fee) = manager.getSlot0(poolId);
         assertEq(fee,10000);
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

    // permit generator
    bytes32 public constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bytes32 public constant _PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bytes32 public constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    bytes32 public constant _PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    bytes32 public constant _PERMIT_BATCH_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    function getPermitSignatureRaw(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permit.details));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permit.spender, permit.sigDeadline))
            )
        );

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    function getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignatureRaw(permit, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }


    function getCompactPermitTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal view returns (bytes memory sig) {
        bytes32 tokenPermissions = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        _PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, address(this), permit.nonce, permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes32 vs;
        (r, vs) = _getCompactSignature(v, r, s);
        return bytes.concat(r, vs);
    }

    function _getCompactSignature(uint8 vRaw, bytes32 rRaw, bytes32 sRaw)
        internal
        pure
        returns (bytes32 r, bytes32 vs)
    {
        uint8 v = vRaw - 27; // 27 is 0, 28 is 1
        vs = bytes32(uint256(v) << 255) | sRaw;
        return (rRaw, vs);
    }

    function defaultERC20PermitTransfer(address token0, uint256 nonce,uint256 amount, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token0, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

      function getPermitTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal view returns (bytes memory sig) {
        bytes32 tokenPermissions = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        _PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, address(this), permit.nonce, permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    /// @notice Swap tokens
    /// @param key the pool where the swap is happening
    /// @param amountSpecified the amount of tokens to swap
    /// @param zeroForOne whether the swap is token0 -> token1 or token1 -> token0
    /// @param nbSponsored mock to simulate multiple call
    function customSwap(
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne,
        uint256 nbSponsored
    ) internal {
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
        if (nbSponsored > 0) {
            // mock test
            hookData = abi.encode(uint24(nbSponsored));
        }
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        swapRouter.swap(key, params, testSettings, hookData);
    }

    /// @notice Swap tokens
    /// @param key the pool where the swap is happening
    /// @param amountSpecified the amount of tokens to swap
    /// @param zeroForOne whether the swap is token0 -> token1 or token1 -> token0
    /// @param permitInfos permit2 signature sponsored swap
    function customSwapSigned(
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne,
        bytes memory permitInfos
    ) public {
        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            });

        IPermit2 PERMIT2 =IPermit2(permit2);

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
                // todo swap part
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

      /// @notice Transfers a token using a signed permit message.
    /// @param permit The permit data signed over by the owner
    /// @param dataHash The EIP-712 hash of permit data to include when checking signature
    /// @param owner The owner of the tokens to transfer
    /// @param transferDetails The spender's requested transfer details for the permitted token
    /// @param signature The signature to verify
    function _permitTransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 dataHash,
        bytes calldata signature
    ) private {
        uint256 requestedAmount = transferDetails.requestedAmount;

    
        signature.verify(_hashTypedData(dataHash), owner);
    }
  /// @notice Creates an EIP-712 typed data hash
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, dataHash));
    }
}
