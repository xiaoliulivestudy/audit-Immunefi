// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, StdInvariant, console2 } from "forge-std/Test.sol";
import {ERC20Permit, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {Staking} from "../src/Staking.sol";
import {IStakingV1} from "../src/interfaces/IStakingV1.sol";
import {IMigratorV1} from "../src/interfaces/IMigratorV1.sol";
import {IMigratorReceiverV2} from "../src/interfaces/IMigratorReceiverV2.sol";
import {StakingHandler} from "./StakingHandler.t.sol";

contract Token is ERC20Permit {
    constructor() ERC20Permit("TestToken") ERC20("TestToken", "TTKN") {}
}

// q 有什么其他
contract UnsupportedToken is ERC20Permit {
    constructor() ERC20Permit("UnsupportedToken") ERC20("UnsupportedToken", "UTKN") {}
}

contract Invariant is StdInvariant, Test {
    Staking public staking;
    Token public token;
    StakingHandler public handler;

    address public admin = address(2);
    address public manager = address(3);
    address public migrator = address(4);
    address public pauser = address(5);


    function setUp() public {
        token = new Token();
        staking = new Staking(admin, manager, pauser, address(token));

        vm.startPrank(admin);
        staking.grantRole(keccak256("MIGRATOR"), migrator);
        vm.stopPrank();
        handler= new StakingHandler(staking, token); // 现在 Token 可以隐式转换为 ERC20Permit

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = StakingHandler.Test_stake.selector;
        selectors[1] = StakingHandler.Test_stakeWithPermit.selector;
        selectors[2] = StakingHandler.Test_withdraw.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    // require(activeTotalStaked + activeTotalRewards + reward <= contractBalance);
    // anwser: 不能被打破
    function invariant_contractBalance() public {
        assertEq(token.balanceOf(address(staking)), staking.getactiveTotalStaked() + staking.getactiveTotalRewards());
        // assertGe(token.balanceOf(address(staking)), staking.getactiveTotalStaked() + staking.getactiveTotalRewards());
    }

}
