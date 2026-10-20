// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {YoloToken} from "../src/YoloToken.sol";

/// @notice Drives YoloToken with random sequences of every state-changing call, from several actors,
/// with bounded inputs. It keeps an independent model of balances, allowances and burns (a plain
/// ledger, not a copy of the token's code) and checks each call's outcome against it: a call the
/// model says must succeed has to succeed with exactly the modelled effect, and a call the model says
/// must fail has to revert with exactly the modelled error and change nothing.
/// @dev The handler is the token's deployer, so it starts with the whole supply, as the launch
/// factory does. It never reverts itself; every mismatch is counted in `violations`.
contract YoloHandler is Test {
    YoloToken public immutable token;
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    address[] internal actors;

    // Model.
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;
    uint256 public ghostBurned;
    uint256 public ghostLastSupply;

    // Outcome bookkeeping.
    uint256 public violations;
    string public lastViolation;
    mapping(bytes32 => uint256) public calls;

    constructor() {
        token = new YoloToken();
        modelBalance[address(this)] = SUPPLY;
        ghostLastSupply = SUPPLY;
        actors.push(address(this));
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ------------------------------------------------------------------------------------------
    // Input shaping
    // ------------------------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Mostly amounts the caller can afford, sometimes exactly the balance, sometimes one more,
    /// sometimes anything up to the supply, so both the success and the failure paths are reached.
    function _amount(uint256 raw, uint256 available) internal pure returns (uint256) {
        uint256 mode = raw % 6;
        if (mode == 0) return available;
        if (mode == 1) return available == type(uint256).max ? available : available + 1;
        if (mode == 2) return 0;
        if (mode == 3) return bound(raw, 0, SUPPLY);
        return available == 0 ? 0 : bound(raw, 0, available);
    }

    function _flag(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    function _expectSuccess(bool ok, bytes memory ret, string memory why) internal returns (bool) {
        if (!ok) {
            _flag(why);
            return false;
        }
        if (ret.length != 0 && !abi.decode(ret, (bool))) {
            _flag(string.concat(why, ": returned false"));
            return false;
        }
        return true;
    }

    function _expectRevert(bool ok, bytes memory ret, bytes memory expected, string memory why) internal {
        if (ok || keccak256(ret) != keccak256(expected)) _flag(why);
    }

    // ------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        calls["transfer"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = modelBalance[from];
        uint256 amount = _amount(rawAmount, held);

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.transfer, (to, amount)));
        if (amount > held) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, from, held, amount),
                "transfer above balance did not revert as modelled"
            );
        } else if (_expectSuccess(ok, ret, "affordable transfer reverted")) {
            modelBalance[from] -= amount;
            modelBalance[to] += amount;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 rawAmount) external {
        calls["transferToZero"]++;
        address from = _actor(fromSeed);
        uint256 amount = _amount(rawAmount, modelBalance[from]);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.transfer, (address(0), amount)));
        _expectRevert(ok, ret, abi.encodeWithSelector(YoloToken.ZeroAddress.selector), "transfer to zero accepted");
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        calls["approve"]++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Sometimes unlimited, otherwise anything up to twice the supply.
        uint256 amount = rawAmount % 5 == 0 ? type(uint256).max : bound(rawAmount, 0, 2 * SUPPLY);
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.approve, (spender, amount)));
        if (_expectSuccess(ok, ret, "approve reverted")) modelAllowance[owner][spender] = amount;
    }

    function increaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        calls["increaseAllowance"]++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = modelAllowance[owner][spender];
        uint256 room = type(uint256).max - current;
        // Sometimes exactly the room left, sometimes one past it (the overflow path).
        uint256 added = rawAmount % 7 == 0
            ? (rawAmount % 2 == 1 && room < type(uint256).max ? room + 1 : room)
            : bound(rawAmount, 0, SUPPLY);
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.increaseAllowance, (spender, added)));
        if (added > type(uint256).max - current) {
            // Checked addition: Panic(0x11).
            _expectRevert(
                ok, ret, abi.encodeWithSignature("Panic(uint256)", uint256(0x11)), "allowance overflow accepted"
            );
        } else if (_expectSuccess(ok, ret, "increaseAllowance reverted")) {
            modelAllowance[owner][spender] = current + added;
        }
    }

    function decreaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        calls["decreaseAllowance"]++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = modelAllowance[owner][spender];
        uint256 cut = _amount(rawAmount, current == type(uint256).max ? SUPPLY : current);
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.decreaseAllowance, (spender, cut)));
        if (cut > current) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, spender, current, cut),
                "decrease below zero did not revert as modelled"
            );
        } else if (_expectSuccess(ok, ret, "decreaseAllowance reverted")) {
            modelAllowance[owner][spender] = current - cut;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 rawAmount) external {
        calls["transferFrom"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = modelAllowance[owner][spender];
        uint256 held = modelBalance[owner];
        uint256 amount = rawAmount % 2 == 0 ? _amount(rawAmount >> 1, held) : _amount(rawAmount >> 1, allowed);

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.transferFrom, (owner, to, amount)));
        if (allowed != type(uint256).max && amount > allowed) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, spender, allowed, amount),
                "transferFrom above allowance did not revert as modelled"
            );
        } else if (amount > held) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, owner, held, amount),
                "transferFrom above balance did not revert as modelled"
            );
        } else if (_expectSuccess(ok, ret, "permitted transferFrom reverted")) {
            if (allowed != type(uint256).max) modelAllowance[owner][spender] = allowed - amount;
            modelBalance[owner] -= amount;
            modelBalance[to] += amount;
        }
    }

    function burn(uint256 fromSeed, uint256 rawAmount) external {
        calls["burn"]++;
        address from = _actor(fromSeed);
        uint256 held = modelBalance[from];
        // Keep big burns rare so the rest of the sequence still has balances to move.
        uint256 amount = rawAmount % 3 == 0 ? _amount(rawAmount, held) : bound(rawAmount, 0, held / 100 + 1);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.burn, (amount)));
        if (amount > held) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, from, held, amount),
                "burn above balance did not revert as modelled"
            );
        } else if (_expectSuccess(ok, ret, "affordable burn reverted")) {
            modelBalance[from] -= amount;
            ghostBurned += amount;
        }
    }

    function burnFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 rawAmount) external {
        calls["burnFrom"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = modelAllowance[owner][spender];
        uint256 held = modelBalance[owner];
        uint256 amount = rawAmount % 2 == 0 ? _amount(rawAmount >> 1, held / 100 + 1) : _amount(rawAmount >> 1, allowed);
        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(YoloToken.burnFrom, (owner, amount)));
        if (allowed != type(uint256).max && amount > allowed) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientAllowance.selector, spender, allowed, amount),
                "burnFrom above allowance did not revert as modelled"
            );
        } else if (amount > held) {
            _expectRevert(
                ok,
                ret,
                abi.encodeWithSelector(YoloToken.InsufficientBalance.selector, owner, held, amount),
                "burnFrom above balance did not revert as modelled"
            );
        } else if (_expectSuccess(ok, ret, "permitted burnFrom reverted")) {
            if (allowed != type(uint256).max) modelAllowance[owner][spender] = allowed - amount;
            modelBalance[owner] -= amount;
            ghostBurned += amount;
        }
    }

    /// @notice Anything that looks like a privileged mint or seizure, from any actor, must fail and
    /// change nothing.
    function tryPrivileged(uint256 callerSeed, uint256 victimSeed, uint256 which) external {
        calls["tryPrivileged"]++;
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        bytes[6] memory attempts = [
            abi.encodeWithSignature("mint(address,uint256)", caller, SUPPLY),
            abi.encodeWithSignature("mint(uint256)", SUPPLY),
            abi.encodeWithSignature("seize(address)", victim),
            abi.encodeWithSignature("freeze(address)", victim),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", caller)
        ];
        vm.prank(caller);
        (bool ok,) = address(token).call(attempts[which % attempts.length]);
        if (ok) _flag("a privileged-looking call succeeded");
    }

    /// @notice Records the supply after each call so the monotonicity invariant can compare.
    function checkpointSupply() external {
        uint256 now_ = token.totalSupply();
        if (now_ > ghostLastSupply) _flag("supply grew");
        ghostLastSupply = now_;
    }
}

contract YoloTokenInvariantTest is Test {
    YoloHandler handler;
    YoloToken token;

    function setUp() public {
        handler = new YoloHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = YoloHandler.transfer.selector;
        selectors[1] = YoloHandler.transferToZero.selector;
        selectors[2] = YoloHandler.approve.selector;
        selectors[3] = YoloHandler.increaseAllowance.selector;
        selectors[4] = YoloHandler.decreaseAllowance.selector;
        selectors[5] = YoloHandler.transferFrom.selector;
        selectors[6] = YoloHandler.burn.selector;
        selectors[7] = YoloHandler.burnFrom.selector;
        selectors[8] = YoloHandler.tryPrivileged.selector;
        selectors[9] = YoloHandler.checkpointSupply.selector;
        selectors[10] = YoloHandler.transfer.selector; // weight ordinary transfers
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every call behaved as the model said: success where it had to succeed, the exact
    /// error where it had to fail.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCallMatchesTheModel() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @notice Conservation: the holders' balances sum to totalSupply, and totalSupply is the
    /// initial supply less exactly what was burned. Nothing is created and nothing leaks.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupplyAndSupplyOnlyShrinksByBurns() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to totalSupply");
        assertEq(token.totalSupply(), handler.SUPPLY() - handler.ghostBurned(), "supply != initial - burned");
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY(), "supply above the fixed cap");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @notice Every balance and every allowance equals the model's, so no call moved anything it
    /// did not say it moved.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesAndAllowancesMatchTheModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.modelBalance(a), "balance diverged from the model");
            for (uint256 j; j < n; ++j) {
                address b = handler.actorAt(j);
                assertEq(token.allowance(a, b), handler.modelAllowance(a, b), "allowance diverged from the model");
            }
        }
    }

    /// @notice Metadata is fixed whatever happens.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "moneycanbuy");
        assertEq(token.symbol(), "YOLO");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 ether);
    }
}
