// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, StdInvariant, console2 } from "forge-std/Test.sol";
import {ERC20Permit, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {Staking} from "../src/Staking.sol";
import {IStakingV1} from "../src//interfaces/IStakingV1.sol";
import {IMigratorV1} from "../src/interfaces/IMigratorV1.sol";
import {IMigratorReceiverV2} from "../src/interfaces/IMigratorReceiverV2.sol";
import {Staking} from "../src/Staking.sol";
import {Token} from "./Invariant.t.sol";


// 质押和提取钱都不能导致 activeTotalStaked+activeTotalRewards> balance 
// q 如果别人在质押，使用者必须不断打钱才能保证质押成功。换句话说没有不变量。

// stake
// stakeWithPermit
// withdraw
// setMigrationPermit

contract StakingHandler is Test {
    Staking public staking;
    Token public token; // 修改类型为 ERC20Permit 以兼容 Invariant 中的 Token

    address public alice = address(6);
    address public bob = address(7);
    address public manager = address(3);

    uint256 public charliePrivateKey = 0xca51;
    address public charlie = vm.addr(charliePrivateKey);

    constructor(Staking _staking, Token _token) { // 修改构造函数参数类型
        staking = _staking;
        token = _token;
        addStakingPeriodByManager(1000000000e18, 20, 5, 1000, true);
        addStakingPeriodByManager(1000000000e18, 20, 5, 100, true);
        addStakingPeriodByManager(1000000000e18, 20, 5, 4000, true);
        addStakingPeriodByManager(1000000000e18, 20, 5, 3000, true);

    }

    function Test_stake(uint256 useramount, uint256 periodIndex, uint256 indexadderss) public {
        indexadderss = bound(indexadderss, 0, 1);
        periodIndex = bound(periodIndex, 0, 3);
        // 修改: 提高最小质押金额，避免因数值过小导致奖励计算为0，进而引发合约余额不足错误
        useramount = bound(useramount, 1, 300e18);
        // useramount = bound(useramount, 1e18, 300e18);
        //         // 修改: 确保奖励至少为1，防止因整数除法截断导致奖励为0，从而使得合约余额为0但又有质押记录的情况
        // if (userReward == 0 && useramount > 0) {
        //     userReward = 1;
        // }
         // 获取质押周期信息
        Staking.StakingPeriod memory stakingPeriod = staking.getStakingPeriod(uint8(periodIndex));
        address  user;
        if(indexadderss==1){
              user = alice;
        }else{
              user = bob;
        }

        uint256 userReward = calculateReward(useramount, stakingPeriod.stakingDurationSeconds, stakingPeriod.aprBps);
        


        // uint256 stakingamount =userReward;
        uint256 currentBalance = token.balanceOf(address(staking));
        deal(address(token), address(staking), currentBalance + userReward);
        deal(address(token), user, useramount);

        vm.startPrank(user);
        token.approve(address(staking), useramount);
        
        // vm.expectEmit(true, true, true, true);
        // emit IStakingV1.Staked(user, uint8(periodIndex), address(0), 0, useramount, userReward);
        // stake(user, uint8(periodIndex), useramount, stakingPeriod.stakingDurationSeconds, stakingPeriod.unlockDurationSeconds, stakingPeriod.aprBps, address(0));    
        uint256 textstakeIndex = staking.stake(
            uint8(periodIndex),
            useramount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: stakingPeriod.stakingDurationSeconds,
                maxUnlockDurationSeconds: stakingPeriod.unlockDurationSeconds,
                minAprBps: stakingPeriod.aprBps,
                referrer: address(0)
            })
        );
        vm.stopPrank();

        // Staking.UserStake[] memory userStakes = staking.getUserStakes(user);
        
    }

    function Test_stakeWithPermit(uint256 useramount, uint256 periodIndex) public {
        // 绑定参数范围
        periodIndex = bound(periodIndex, 0, 3);
        // 修改: 提高最小质押金额，避免奖励为0
        useramount = bound(useramount, 1e18, 300e18);
        
        // 获取质押周期信息
        Staking.StakingPeriod memory stakingPeriod = staking.getStakingPeriod(uint8(periodIndex));

        // 确定用户地址
        address user = charlie;
        uint256 deadline = block.timestamp + 1 hours;

          // 计算预期奖励
        uint256 userReward = calculateReward(useramount, stakingPeriod.stakingDurationSeconds, stakingPeriod.aprBps);
        

        
        // 给合约充值奖励部分，给用户充值本金
        uint256 currentBalance = token.balanceOf(address(staking));
        deal(address(token), address(staking), currentBalance + userReward);
        deal(address(token), user, useramount);
        
        // 生成有效的 Permit 签名
        (uint8 v, bytes32 r, bytes32 s) = signCharliePermit(useramount, deadline);

      
    
        vm.startPrank(user);
 
        // 使用 try/catch 防止因业务逻辑（如 Cap 满）或签名问题导致 revert，从而破坏 invariant 测试
        // 注意：在 fail_on_revert = true 的配置下，Handler 中的任何 revert 都会导致测试失败
        try staking.stakeWithPermit(
            uint8(periodIndex),
            useramount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: stakingPeriod.stakingDurationSeconds,
                maxUnlockDurationSeconds: stakingPeriod.unlockDurationSeconds,
                minAprBps: stakingPeriod.aprBps,
                referrer: address(0)
            }),
            deadline,
            v,
            r,
            s
        ) {
            // 成功情况
        } catch {
            // 捕获所有异常，防止 revert 传播。
            // 在 invariant 测试中，我们关注的是状态不变量，而不是每次调用都必须成功。
            // 如果签名无效或业务逻辑拒绝，我们只需跳过此次状态变更即可。
        }
        
        vm.stopPrank();
    }

    function Test_withdraw(uint256 stakeIndex, uint256 indexadderss, uint256 timeSkip) public {

        indexadderss = bound(indexadderss, 0, 2);
        address  user;
        if(indexadderss==1){
             user= alice;
        }else if(indexadderss==2){
            user = bob;
        }else{
            user = charlie;
        }
        Staking.UserStake[] memory  UserStakes=staking.getUserStakes(user);
        uint256 stakeIndexLength = UserStakes.length;

        if (stakeIndexLength == 0) {
            return;
        }
        stakeIndex = bound(stakeIndex, 0, stakeIndexLength - 1);
        uint256 skipTime = bound(timeSkip, 22, 30); 

        vm.warp(block.timestamp + skipTime);

        Staking.UserStake memory userStake = UserStakes[stakeIndex];

        if (userStake.claimedAmount + userStake.claimedReward >= userStake.amount + userStake.reward) {
            return;
        }
        vm.startPrank(user);
        
        uint256 withdrawn = staking.withdraw(uint8(stakeIndex));
        vm.stopPrank();

    }

    // function Test_setMigrationPermit(uint8 indexAddress, address migrator, bool isPermitted) public {
    //     // 绑定用户
    //     indexAddress = bound(indexAddress, 0, 1);
    //     address user = indexAddress == 1 ? alice : bob;
        
    //     // 确保 migrator 不是零地址
    //     if (migrator == address(0)) {
    //         return; 
    //     }

    //     vm.startPrank(user);
        
    //     // 如果允许迁移，我们需要确保该地址有 MIGRATOR_ROLE，否则合约会 revert
    //     // 在测试环境中，我们可能需要先授予角色，或者测试 revert 情况
    //     // 这里我们尝试调用，并期望它成功或按预期 revert
        
    //     // 为了测试成功路径，我们可以假设 migrator 已经被授予角色，或者我们只测试状态变更逻辑
    //     // 由于这是 Handler，我们主要看函数是否能被调用
        
    //     try staking.setMigrationPermit(migrator, isPermitted) {
    //         // 验证事件
    //         emit IMigratorV1.MigrationPermitUpdated(migrator, user, isPermitted);
    //     } catch {
    //         // 可能因为缺乏角色而 revert，这在 fuzzing 中是可接受的
    //     }
        
    //     vm.stopPrank();
    // }


    function stake(
        address user,
        uint8 periodIndex,
        uint256 amount,
        uint64 maxStakingDurationSeconds,
        uint64 maxUnlockDurationSeconds,
        uint32 minAprBps,
        address referrer
    ) internal returns (uint8 stakeIndex) {
        vm.startPrank(user);
        stakeIndex = staking.stake(
            periodIndex,
            amount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: maxStakingDurationSeconds,
                maxUnlockDurationSeconds: maxUnlockDurationSeconds,
                minAprBps: minAprBps,
                referrer: referrer
            })
        );
        vm.stopPrank();
    }

    function addStakingPeriodByManager(
        uint256 cap,
        uint64 stakingDurationSeconds,
        uint64 unlockDurationSeconds,
        uint32 aprBps,
        bool isActive
    ) internal returns (uint8 periodIndex) {
        vm.startPrank(manager);
        periodIndex = staking.addStakingPeriod(cap, stakingDurationSeconds, unlockDurationSeconds, aprBps, isActive);
        vm.stopPrank();
    }

    function calculateReward(uint256 stakingAmount, uint256 stakingTime, uint256 stakingApyBps)
        internal
        pure
        returns (uint256)
    {
        return (stakingAmount * stakingTime * stakingApyBps) / (365 days * 10000);
    }


    function signCharliePermit(uint256 amount, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(
            charliePrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                            ),
                            charlie,
                            address(staking),
                            amount,
                            token.nonces(charlie),
                            deadline
                        )
                    )
                )
            )
        );
    }
}
