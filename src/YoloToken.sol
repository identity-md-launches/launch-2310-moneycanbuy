// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title moneycanbuy (YOLO)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 YOLO (18 decimals) is
/// minted once, in the constructor, to the deployer. Nothing can mint afterwards.
/// @dev Deliberately minimal: no owner, no pause, no blocklist, no tax, no upgrade path. The only
/// way the supply ever changes is a holder burning their own tokens (or an allowance they were
/// granted). Ordinary transfers move exactly the amount requested, so launch flows arrive whole.
contract YoloToken {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Token name as shown by wallets and explorers.
    string public constant name = "moneycanbuy";

    /// @notice Token ticker.
    string public constant symbol = "YOLO";

    /// @notice Minor units per whole token.
    uint8 public constant decimals = 18;

    /// @notice The fixed supply, in minor units: one billion whole tokens.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Current supply. Starts at INITIAL_SUPPLY and can only ever shrink through burns.
    uint256 public totalSupply;

    /// @notice Balance of each holder.
    mapping(address account => uint256) public balanceOf;

    /// @notice Amount `spender` may move from `owner` via transferFrom.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice ERC-20 transfer event. A burn is a Transfer to the zero address.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice ERC-20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but only holds `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to move `needed` from an owner that only allowed `allowed`.
    error InsufficientAllowance(address spender, uint256 allowed, uint256 needed);

    /// @notice Transfers and approvals involving the zero address are refused. Use burn instead.
    error ZeroAddress();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the whole fixed supply to the deployer.
    /// @dev At launch the deployer is the launch factory, which then distributes the supply. There
    /// are no constructor arguments, no external calls, and no owner is recorded.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    /// @dev Standard ERC-20 approve. Prefer increaseAllowance / decreaseAllowance when changing an
    /// existing non-zero allowance, to avoid the approve race.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance.
    /// @dev An allowance of type(uint256).max is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `addedValue`.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtractedValue`.
    /// @dev Reverts with InsufficientAllowance if the current allowance is smaller than the cut.
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) revert InsufficientAllowance(spender, current, subtractedValue);
        _approve(msg.sender, spender, current - subtractedValue);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Burning: the only way the supply changes after deployment, and only by the holder's choice.
    // ---------------------------------------------------------------------------------------------

    /// @notice Destroys `amount` of the caller's own tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` of `from`'s tokens using the caller's allowance.
    /// @dev Only an allowance `from` explicitly granted lets anyone burn their balance. Nobody holds
    /// a privileged path to this.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was just checked, and the sum of all balances is totalSupply,
            // which fits in uint256, so neither line can overflow.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
