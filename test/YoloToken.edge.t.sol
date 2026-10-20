// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {YoloToken} from "../src/YoloToken.sol";

/// @notice Deploys the token the way the launch factory does, by CREATE2 from a contract, and then
/// performs the launch's first moves in the same call: the swarm's 10% to a distributor, 60% to a
/// pool, the remaining 30% to the requester.
contract LaunchLike {
    function launch(bytes32 salt, address distributor, address pool, address requester)
        external
        returns (YoloToken token, uint256 heldAfterDeploy, uint256 supplyAfterDeploy)
    {
        token = new YoloToken{salt: salt}();
        heldAfterDeploy = token.balanceOf(address(this));
        supplyAfterDeploy = token.totalSupply();
        uint256 supply = token.totalSupply();
        require(token.transfer(distributor, supply / 10), "swarm");
        require(token.transfer(pool, (supply * 6000) / 10_000), "pool");
        require(token.transfer(requester, token.balanceOf(address(this))), "remainder");
    }
}

/// @notice Edge cases and failure paths not covered by YoloToken.t.sol.
contract YoloTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    YoloToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        token = new YoloToken(); // this contract is the deployer and holds the supply
    }

    // ------------------------------------------------------------------------------------------
    // Launch flow
    // ------------------------------------------------------------------------------------------

    function test_launchFlowsArriveExactlyInOneCall() public {
        LaunchLike factory = new LaunchLike();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address requester = makeAddr("requester");
        (YoloToken t, uint256 held, uint256 supply) = factory.launch(bytes32(uint256(7)), distributor, pool, requester);
        assertEq(held, SUPPLY);
        assertEq(supply, SUPPLY);
        assertEq(t.balanceOf(distributor), 100_000_000 ether);
        assertEq(t.balanceOf(pool), 600_000_000 ether);
        assertEq(t.balanceOf(requester), 300_000_000 ether);
        assertEq(t.balanceOf(address(factory)), 0);
        assertEq(t.totalSupply(), SUPPLY);

        // The distributor's claims leave it whole.
        vm.prank(distributor);
        t.transfer(alice, 100_000_000 ether);
        assertEq(t.balanceOf(alice), 100_000_000 ether);
        assertEq(t.balanceOf(distributor), 0);
    }

    function test_constructorMintsToTheCreatorNotTheOrigin() public {
        LaunchLike factory = new LaunchLike();
        vm.prank(alice, alice); // tx.origin = alice, but the factory is the creator
        (YoloToken t,,) = factory.launch(bytes32(0), bob, bob, bob);
        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(bob), SUPPLY);
    }

    function test_transferOfTheWholeSupplyArrivesWhole() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
    }

    function test_RevertWhen_transferOneMoreThanTheSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_RevertWhen_transferMaxUint() public {
        vm.expectRevert(
            abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------
    // Allowances
    // ------------------------------------------------------------------------------------------

    function test_transferFromExactAllowanceLeavesZero() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        token.transferFrom(alice, carol, 10 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_transferFromSelfStillNeedsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_transferFromZeroAmountWithoutAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromToOwnerKeepsBalanceButSpendsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.prank(bob);
        token.transferFrom(alice, alice, 4 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_unlimitedAllowanceTransferFromEmitsNoApproval() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Transfer.selector);
    }

    function test_unlimitedAllowanceCanDrainThenStopsAtBalance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_allowanceIsPerSpenderAndPerOwner() public {
        token.transfer(alice, 10 ether);
        token.transfer(carol, 10 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        // bob's allowance from alice does not let carol spend, nor bob spend carol's.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(carol, bob, 1);
    }

    function test_decreaseAllowanceToExactlyZero() public {
        vm.startPrank(alice);
        token.approve(bob, 3 ether);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 0);
        token.decreaseAllowance(bob, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_decreaseUnlimitedAllowanceMakesItFinite() public {
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        token.decreaseAllowance(bob, 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
        token.transfer(alice, 5 ether);
        vm.prank(bob);
        token.transferFrom(alice, carol, 5 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1 - 5 ether);
    }

    function test_increaseAllowanceToExactlyMaxBecomesUnlimited() public {
        vm.startPrank(alice);
        token.approve(bob, 1);
        token.increaseAllowance(bob, type(uint256).max - 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_RevertWhen_increaseAllowanceOverflowsWithPanic() public {
        vm.startPrank(alice);
        token.approve(bob, 2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        token.increaseAllowance(bob, type(uint256).max - 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2);
    }

    function test_RevertWhen_increaseAllowanceZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        token.increaseAllowance(address(0), 1);
    }

    function test_RevertWhen_decreaseAllowanceZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        token.decreaseAllowance(address(0), 0);
    }

    function test_RevertWhen_decreaseAllowanceWithNone() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 0, 1));
        token.decreaseAllowance(bob, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Burns
    // ------------------------------------------------------------------------------------------

    function test_burnTheWholeSupply() public {
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
    }

    function test_burnZeroChangesNothing() public {
        vm.prank(alice);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnFromWithUnlimitedAllowanceDoesNotDecrement() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.burnFrom(alice, 10 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
    }

    function test_RevertWhen_burnFromExceedsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, 2 ether, 3 ether));
        token.burnFrom(alice, 3 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_burnFromExceedsBalanceRestoresAllowance() public {
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.burnFrom(alice, 2 ether);
        assertEq(token.allowance(alice, bob), 5 ether);
    }

    function test_burnFromEmitsApprovalThenTransferToZero() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 3 ether);
        vm.prank(bob);
        token.burnFrom(alice, 3 ether);
    }

    function test_RevertWhen_burnFromTheZeroAddress() public {
        // Nobody can hold an allowance from address(0), and it holds nothing.
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, address(this), 0, 1));
        token.burnFrom(address(0), 1);
    }

    function test_burnedTokensCannotBeTransferredFromZero() public {
        token.burn(1 ether);
        assertEq(token.balanceOf(address(0)), 0);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, address(0), 0, 1));
        token.transfer(alice, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz: arithmetic at the edges
    // ------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anySenderAnyAmountEitherMovesExactlyOrRevertsCleanly(
        address from,
        address to,
        uint256 seeded,
        uint256 amount
    ) public {
        if (from == address(vm) || from == address(0)) from = alice;
        seeded = bound(seeded, 0, SUPPLY);
        if (from != address(this)) token.transfer(from, seeded);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        if (to == address(0)) {
            vm.expectRevert(YoloToken.ZeroAddress.selector);
            token.transfer(to, amount);
        } else if (amount > fromBefore) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, from, fromBefore, amount));
            token.transfer(to, amount);
        } else {
            assertTrue(token.transfer(to, amount));
            if (from == to) {
                assertEq(token.balanceOf(from), fromBefore);
            } else {
                assertEq(token.balanceOf(from), fromBefore - amount);
                assertEq(token.balanceOf(to), toBefore + amount);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_burnFromNeverExceedsBothLimits(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, bob, allowed, amount));
            token.burnFrom(alice, amount);
            assertEq(token.totalSupply(), SUPPLY);
        } else if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, alice, held, amount));
            token.burnFrom(alice, amount);
            assertEq(token.totalSupply(), SUPPLY);
        } else {
            token.burnFrom(alice, amount);
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.allowance(alice, bob), allowed - amount);
            assertEq(token.totalSupply(), SUPPLY - amount);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_increaseThenDecreaseRoundTrips(uint256 start, uint256 delta) public {
        start = bound(start, 0, type(uint256).max);
        delta = bound(delta, 0, type(uint256).max - start);
        vm.startPrank(alice);
        token.approve(bob, start);
        token.increaseAllowance(bob, delta);
        assertEq(token.allowance(alice, bob), start + delta);
        token.decreaseAllowance(bob, delta);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), start);
    }
}
