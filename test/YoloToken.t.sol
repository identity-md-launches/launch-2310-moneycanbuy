// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YoloToken} from "../src/YoloToken.sol";

/// @notice A deployer stand-in: deploys the token the way the launch factory does (as msg.sender of
/// the constructor) and forwards transfers only when the test asks.
contract Deployer {
    function deploy() external returns (YoloToken) {
        return new YoloToken();
    }

    function send(YoloToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract YoloTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    Deployer deployer;
    YoloToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        deployer = new Deployer();
        token = deployer.deploy();
    }

    // ------------------------------------------------------------------------------------------
    // Metadata and initial state
    // ------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "moneycanbuy");
        assertEq(token.symbol(), "YOLO");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(deployer)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        Deployer fresh = new Deployer();
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(fresh), SUPPLY);
        fresh.deploy();
    }

    function test_supplyIsExactlyOneBillionWholeTokens() public view {
        assertEq(token.totalSupply() / (10 ** token.decimals()), 1_000_000_000);
        assertEq(token.totalSupply() % (10 ** token.decimals()), 0);
    }

    // ------------------------------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(deployer), alice, 1_000 ether);
        assertTrue(deployer.send(token, alice, 1_000 ether));

        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferChainArrivesWhole() public {
        // deployer -> alice -> bob -> carol: no fee, no rounding, nothing lost.
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.transfer(bob, 10 ether);
        vm.prank(bob);
        token.transfer(carol, 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 10 ether);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        deployer.send(token, alice, 5 ether);
        vm.prank(alice);
        token.transfer(alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_transferWholeBalanceLeavesZero() public {
        deployer.send(token, alice, 5 ether);
        vm.prank(alice);
        token.transfer(bob, 5 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        deployer.send(token, alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 5 ether, 5 ether + 1));
        token.transfer(bob, 5 ether + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        deployer.send(token, alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        token.transfer(address(0), 1 ether);
    }

    // ------------------------------------------------------------------------------------------
    // approve / transferFrom / allowance helpers
    // ------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 7 ether);
        vm.prank(alice);
        assertTrue(token.approve(bob, 7 ether));
        assertEq(token.allowance(alice, bob), 7 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(alice);
        token.approve(bob, 7 ether);
        token.approve(bob, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2 ether);
    }

    function test_RevertWhen_approveZeroAddressSpender() public {
        vm.prank(alice);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceAndEmits() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 6 ether);

        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 2 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 4 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 4 ether));

        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.balanceOf(carol), 4 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 2 ether);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 4 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 4 ether);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(alice, carol, 1 ether);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 3 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 3 ether, 3 ether + 1));
        token.transferFrom(alice, carol, 3 ether + 1);
    }

    function test_RevertWhen_transferFromExceedsBalanceEvenWithAllowance() public {
        deployer.send(token, alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, carol, 2 ether);
        // Nothing changed, the allowance included.
        assertEq(token.allowance(alice, bob), 5 ether);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 1 ether);
    }

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(alice);
        assertTrue(token.increaseAllowance(bob, 5 ether));
        assertEq(token.allowance(alice, bob), 5 ether);
        assertTrue(token.increaseAllowance(bob, 1 ether));
        assertEq(token.allowance(alice, bob), 6 ether);
        assertTrue(token.decreaseAllowance(bob, 4 ether));
        assertEq(token.allowance(alice, bob), 2 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_decreaseAllowanceBelowZero() public {
        vm.startPrank(alice);
        token.approve(bob, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 1 ether, 2 ether));
        token.decreaseAllowance(bob, 2 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_increaseAllowanceOverflows() public {
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(); // checked arithmetic panic
        token.increaseAllowance(bob, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // burn / burnFrom
    // ------------------------------------------------------------------------------------------

    function test_burnReducesBalanceAndSupply() public {
        deployer.send(token, alice, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 3 ether);
        vm.prank(alice);
        token.burn(3 ether);
        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.totalSupply(), SUPPLY - 3 ether);
    }

    function test_RevertWhen_burnExceedsBalance() public {
        deployer.send(token, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.burn(2 ether);
    }

    function test_burnFromSpendsAllowance() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.prank(bob);
        token.burnFrom(alice, 4 ether);
        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
    }

    function test_RevertWhen_burnFromWithoutAllowance() public {
        deployer.send(token, alice, 10 ether);
        // Even the deployer cannot burn a holder's tokens without that holder's allowance.
        vm.prank(address(deployer));
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, address(deployer), 0, 1 ether));
        token.burnFrom(alice, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // ------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes
    // ------------------------------------------------------------------------------------------

    function test_noAdminSelectorsExist() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "seize(address)",
            "upgradeTo(address)",
            "setMinter(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(address(deployer));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_deployerCannotMoveAHoldersBalance() public {
        deployer.send(token, alice, 10 ether);
        vm.prank(address(deployer));
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, address(deployer), 0, 1));
        token.transferFrom(alice, address(deployer), 1);
        assertEq(token.balanceOf(alice), 10 ether);

        // and the holder is still free to move.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 5 ether));
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(deployer));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(deployer.send(token, to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(deployer)), token.totalSupply());
    }

    function testFuzz_transferRevertsAboveBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        deployer.send(token, alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        deployer.send(token, alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, allowed, amount));
            token.transferFrom(alice, carol, amount);
        } else {
            token.transferFrom(alice, carol, amount);
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.allowance(alice, bob), allowed - amount);
        }
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        deployer.send(token, alice, held);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertLe(token.totalSupply(), SUPPLY);
    }
}
