// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStakingV1 {
    /**
     * @notice 质押周期配置结构体。
     * @dev 定义了特定质押产品的规则，包括容量、时长和收益率。
     */
    struct StakingPeriod {
        uint256 cap; // 该周期允许的最大质押总量
        uint256 capUsed; // 该周期当前已使用的质押容量
        uint64 stakingDurationSeconds; // 锁仓期时长（秒），在此期间本金不可提取
        uint64 unlockDurationSeconds; // 解锁期时长（秒），在此期间本金和奖励线性释放
        uint32 aprBps; // 年化收益率 (APR)，单位为基点 (bps)。例如：1000 = 10%, 550 = 5.5% (基于365天=31536000秒计算)
        bool isActive; // 标识该周期是否接受新的质押
    }

    /**
     * @notice 用户质押记录结构体。
     * @dev 存储用户单次质押的详细信息，包括本金、奖励、提取进度和时间戳。
     */
    struct UserStake {
        uint256 amount; // 质押本金数量
        uint256 reward; // 预期获得的总奖励数量
        uint256 claimedAmount; // 已提取的本金数量
        uint256 claimedReward; // 已提取的奖励数量
        uint32 aprBps; // 该笔质押适用的年化收益率 (bps)
        uint64 stakeTime; // 质押发生的时间戳
        uint64 unlockTime; // 解锁开始时间戳（即锁仓期结束时间）
        uint64 unlockDuration; // 解锁期总时长（秒）
    }

    /**
     * @notice 质押参数结构体。
     * @dev 用户在发起质押时传入的参数，用于防夹击保护，确保交易执行时的条件符合用户预期。
     */
    struct StakeParams {
        uint64 maxStakingDurationSeconds; // 用户能接受的最大锁仓时长
        uint64 maxUnlockDurationSeconds; // 用户能接受的最大解锁时长
        uint32 minAprBps; // 用户能接受的最小年化收益率
        address referrer; // 推荐人地址（如有）
    }

    event StakingPeriodAdded(
        uint8 indexed periodIndex,
        uint256 cap,
        uint64 stakingDurationSeconds,
        uint64 unlockDurationSeconds,
        uint32 aprBps,
        bool isActive
    );
    event StakingPeriodUpdated(
        uint8 indexed periodIndex,
        uint256 cap,
        uint64 stakingDurationSeconds,
        uint64 unlockDurationSeconds,
        uint32 aprBps,
        bool isActive
    );
    event Staked(
        address indexed user,
        uint8 indexed periodIndex,
        address indexed referrer,
        uint8 stakeIndex,
        uint256 amount,
        uint256 reward
    );
    event Withdrawn(address indexed user, uint8 stakeIndex, uint256 amount, uint256 reward);
    event Recovered(address indexed token, address indexed recipient, uint256 amount);
    event MigrationPermitUpdated(address indexed migrator, address indexed user, bool isMigrationPermitted);
    event MigratedFrom(
        address indexed migrator,
        address indexed user,
        uint8 migratedCount,
        uint256 unclaimedUserAmount,
        uint256 unclaimedUserRewards
    );

    error CannotStakeZero();
    error StakingDurationCannotBeZero();
    error UnlockDurationCannotBeZero();
    error StakingCapReached(uint256 cap);
    error StakingPeriodInactive(uint8 periodIndex);
    error StakingPeriodStakingDurationDiffer(
        uint8 periodIndex, uint64 expectedMaxStakingDuration, uint64 periodStakingDuration
    );
    error StakingPeriodUnlockDurationDiffer(
        uint8 periodIndex, uint64 expectedMaxUnlockDuration, uint64 periodUnlockDuration
    );
    error StakingPeriodAprDiffer(uint8 periodIndex, uint32 expectedMinApr, uint32 periodApr);
    error MaxStakingPeriodsReached();
    error MaxUserStakesReached(uint8 maxStakes);
    error NotEnoughContractBalance(address token, uint256 balance, uint256 requiredBalance);
    error NotEnoughBalanceToRecover(address token, uint256 toRecover, uint256 maxToRecover);
    error RewardsNotAvailableYet(uint64 currentTime, uint64 availableTime);
    error AlreadyWithdrawn(uint8 stakeIndex);
    error PeriodNotFound();
    error StakeNotFound();
    error MigratorNotFound(address migrator);
    error MigratorNotPermitted(address migrator, address user);

    /**
     * @notice 存入代币进行质押。
     * @param periodIndex 目标质押周期的索引。
     * @param amount 质押代币的数量。
     * @param params 质押参数，包含最大时长、最小APR等限制条件。
     * @return stakeIndex 新创建的质押记录在用户列表中的索引。
     */
    function stake(uint8 periodIndex, uint256 amount, StakeParams calldata params) external returns (uint8);

    /**
     * @notice 使用 ERC20 Permit 签名授权并存入代币进行质押。
     * @dev 允许用户在单笔交易中完成授权和质押，无需预先调用 approve。
     * @param periodIndex 目标质押周期的索引。
     * @param amount 质押代币的数量。
     * @param params 质押参数，包含最大时长、最小APR等限制条件。
     * @param deadline 签名的过期时间戳。
     * @param v 签名的 v 值。
     * @param r 签名的 r 值。
     * @param s 签名的 s 值。
     * @return stakeIndex 新创建的质押记录在用户列表中的索引。
     */
    function stakeWithPermit(
        uint8 periodIndex,
        uint256 amount,
        StakeParams calldata params,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint8);

    /**
     * @notice 提取指定质押记录的已解锁本金和奖励。
     * @dev 支持线性解锁，用户可以分多次提取。即使合约暂停，用户仍可提取。
     * @param stakeIndex 要提取的质押记录索引。
     * @return totalWithdrawn 提取的总金额（本金 + 奖励）。
     */
    function withdraw(uint8 stakeIndex) external returns (uint256);

    /**
     * @notice 添加一个新的质押周期配置。
     * @dev 仅管理员可调用。
     * @param _cap 该周期的最大质押容量。
     * @param _stakingDurationSeconds 锁仓期时长（秒）。
     * @param _unlockDurationSeconds 解锁期时长（秒）。
     * @param _aprBps 年化收益率 (bps)。
     * @param _isActive 是否立即激活该周期以接受新质押。
     * @return periodIndex 新添加的质押周期索引。
     */
    function addStakingPeriod(
        uint256 _cap,
        uint64 _stakingDurationSeconds,
        uint64 _unlockDurationSeconds,
        uint32 _aprBps,
        bool _isActive
    ) external returns (uint8);

    /**
     * @notice 更新现有质押周期的配置。
     * @dev 仅管理员可调用。可以修改容量、时长、APR 和激活状态。
     * @param periodIndex 要更新的质押周期索引。
     * @param _cap 新的最大质押容量。
     * @param _stakingDurationSeconds 新的锁仓期时长（秒）。
     * @param _unlockDurationSeconds 新的解锁期时长（秒）。
     * @param _aprBps 新的年化收益率 (bps)。
     * @param _isActive 新的激活状态。
     */
    function updateStakingPeriod(
        uint8 periodIndex,
        uint256 _cap,
        uint64 _stakingDurationSeconds,
        uint64 _unlockDurationSeconds,
        uint32 _aprBps,
        bool _isActive
    ) external;

    /**
     * @notice 获取质押代币的合约地址。
     * @return TOKEN 接口实例。
     */
    function TOKEN() external view returns (IERC20);

    /**
     * @notice 获取所有配置的质押周期。
     * @return 质押周期数组。
     */
    function getStakingPeriods() external view returns (StakingPeriod[] memory);

    /**
     * @notice 获取指定索引的质押周期详情。
     * @param periodIndex 质押周期索引。
     * @return 对应的 StakingPeriod 结构体。
     */
    function getStakingPeriod(uint8 periodIndex) external view returns (StakingPeriod memory);

    /**
     * @notice 获取指定用户的所有质押记录。
     * @param user 用户地址。
     * @return 用户的 UserStake 数组。
     */
    function getUserStakes(address user) external view returns (UserStake[] memory);

    /**
     * @notice 获取指定用户的特定质押记录。
     * @param user 用户地址。
     * @param stakeIndex 质押记录索引。
     * @return 对应的 UserStake 结构体。
     */
    function getUserStake(address user, uint8 stakeIndex) external view returns (UserStake memory);

    /**
     * @notice 计算指定质押记录当前可提取的金额（本金+奖励）。
     * @param user 用户地址。
     * @param stakeIndex 质押记录索引。
     * @return 可提取的总金额。
     */
    function getClaimable(address user, uint8 stakeIndex) external view returns (uint256);

    /**
     * @notice 获取当前所有活跃质押的本金总和。
     * @return 活跃质押本金总量。
     */
    function activeTotalStaked() external view returns (uint256);

    /**
     * @notice 获取当前所有活跃质押的预期奖励总和。
     * @return 活跃质押奖励总量。
     */
    function activeTotalRewards() external view returns (uint256);

    /**
     * @notice 查询合约是否处于暂停状态。
     * @return 如果暂停返回 true，否则返回 false。
     */
    function paused() external view returns (bool);
}
