// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ChessCoin is ERC20, Ownable {
    mapping(address => bool) public minters;

    uint256 public immutable mintCap;
    uint256 public totalMinted;

    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);

    modifier onlyMinter() {
        require(minters[msg.sender], "ChessCoin: caller is not a minter");
        _;
    }

    constructor(uint256 _initialSupply, uint256 _mintCap) ERC20("ChessCoin", "CHSC") {
        require(_mintCap >= _initialSupply, "ChessCoin: cap below initial supply");
        mintCap = _mintCap;
        totalMinted = _initialSupply;
        _mint(msg.sender, _initialSupply);
    }

    function addMinter(address _minter) external onlyOwner {
        minters[_minter] = true;
        emit MinterAdded(_minter);
    }

    function removeMinter(address _minter) external onlyOwner {
        minters[_minter] = false;
        emit MinterRemoved(_minter);
    }

    function mint(address _to, uint256 _amount) external onlyMinter {
        require(totalMinted + _amount <= mintCap, "ChessCoin: mint cap exceeded");
        totalMinted += _amount;
        _mint(_to, _amount);
    }
}
