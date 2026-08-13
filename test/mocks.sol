// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/// @notice Stands in for SHAMBA LUV. Reflections are simulated by `reflect`, which
///         raises a holder's balance without any transfer — which is exactly what an
///         RFI-style token does to a reflection-included address.
contract mock_luv {
    string public name = "SHAMBA LUV";
    string public symbol = "LUV";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public fee_bps; // 0 by default: the locker is fee-exempt in production

    function set_fee_bps(uint256 bps) external {
        fee_bps = bps;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice A reflection landing on `to`. No transfer, no sender, balance just grows.
    function reflect(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        uint256 fee = (amount * fee_bps) / 10_000;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        uint256 fee = (amount * fee_bps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @notice Any other ERC-20 that turns up in the locker by accident.
contract mock_foreign {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
