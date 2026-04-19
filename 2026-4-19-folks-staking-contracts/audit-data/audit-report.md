## Medium
### [M-1]` capUsed`只能增加，不能减少，导致容量无法回收,DOS攻击。
**Description**
`capUsed` 仅在质押时增加，`withdraw` 不减少。导致周期容量一旦占满，即使所有用户退出也无法再接受新质押。尽管管理者可以通过`Staking::::updateStakingPeriod`来更新周期，但敌手还是可以进行抢先攻击。
**Impact**
经济模型设计缺陷，非安全漏洞。可通过新增 decreaseCapUsed 函数或迁移周期解决。但是由于`Staking::addStakingPeriod`中存在以下代码，导致`stakingPeriod`只能有256个，攻击者可以快速把`stakingPeriod`全部使用掉，导致正常用户无法获得奖励，使得质押合约无法正常进行。
似乎没有管理者或所有者可以将资金转出质押或暂停提款。
```javascript
if (stakingPeriods.length > type(uint8).max) revert MaxStakingPeriodsReached();
```

**Proof of Concepts**
```javascript
1. MANAGER_ROLE 可以添加新的`stakingPeriod`。
2. 攻击者一旦发现有`stakingPeriod`，全部质押获取全部奖励，导致`stakingPeriod`无法使用。
3. 其他用户无法使用`stakingPeriod`，进行质押。
4. 循环往复1-3，`Staking`合约失效。
```

**Recommended mitigation**
添加`decreaseCapUsed`函数，设置map`userStakestostakingPeriod`:用户地址->userStakes中的序号->`stakingPeriods`对应的序号。



## Information

### [I-1] Uninitialized local variables
**Description**
Uninitialized local variables. 在/src/Staking.sol文件中有未初始化的变量
```javascript
        uint8 migratedCount;
        uint256 unclaimedUserAmount;
        uint256 unclaimedUserRewards;
        uint256 stakesToMigrateCount;
```
**Recommended mitigation**
Initialize all the variables. If a variable is meant to be initialized to zero, explicitly set it to zero to improve code readability.

### [I-2] 如果amount太小，可能导致没有奖励
**Description**
如果`amount`小于`(1e4 * 365 days)/(stakingPeriod.aprBps * stakingPeriod.stakingDurationSeconds) `，可能导致没有奖励。
**Recommended mitigation**
在质押之前，确认你的`reward`为整数，通过计算得到`amount`。

```javascript
amount=(reward* 1e4 * 365 days)/(stakingPeriod.aprBps * stakingPeriod.stakingDurationSeconds);
```



在/test/invariant.sol文件中进行了不变量测试,发现测试结果为true。