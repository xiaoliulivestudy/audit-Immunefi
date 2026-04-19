// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.30;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {
    AccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakingV1} from "./interfaces/IStakingV1.sol";
import {IMigratorV1} from "./interfaces/IMigratorV1.sol";

/**
 *     @title Fixed APR staking contract
 */
contract Staking is IMigratorV1, Pausable, ReentrancyGuard, AccessControlDefaultAdminRules {
    using SafeERC20 for IERC20;

    /**
     * @notice 管理员角色哈希。
     * @dev 拥有管理权限，如添加/更新质押周期、恢复误转代币等。
     */
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");
    /**
     * @notice 暂停者角色哈希。
     * @dev 拥有暂停或恢复合约质押功能的权限。
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");
    /**
     * @notice 迁移者角色哈希。
     * @dev 拥有执行用户仓位迁移操作的权限（通常用于版本升级）。
     */
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR");

    /**
     * @notice 单个用户允许的最大活跃质押记录数量。
     * @dev 限制为 100，防止用户存储过多记录导致 Gas 消耗过高或数组遍历性能下降。
     */
    uint8 public constant MAX_STAKES_PER_USER = 100;

    // staking and reward token are the same and can be set only once during deployment
    // we assume ERC20 doesn't have any fee on transfer or rebasing logic
    /**
     * @notice 质押代币及奖励代币的地址。
     * @dev 不可变变量，在部署时设定。假设该 ERC20 代币在转账时无手续费且非重基（rebasing）代币。
     */
    IERC20 public immutable TOKEN;

    /**
     * @notice 当前所有活跃质押记录的本金总和。
     * @dev 用于跟踪合约中属于用户且未提取的本金总量，辅助偿付能力检查和代币恢复逻辑。
     */
    uint256 public activeTotalStaked;
    /**
     * @notice 当前所有活跃质押记录的预期奖励总和。
     * @dev 用于跟踪合约中承诺给用户但尚未支付的奖励总量，辅助偿付能力检查和代币恢复逻辑。
     */
    uint256 public activeTotalRewards;

    /**
     * @notice 所有配置的质押周期列表。
     * @dev 每个元素包含该周期的容量、时长、APR 等配置信息。索引即为 periodIndex。
     */
    StakingPeriod[] public stakingPeriods;
    /**
     * @notice 用户地址到其所有质押记录的映射。
     * @dev 存储每个用户的 UserStake 数组，通过 stakeIndex 访问具体记录。
     */
    mapping(address user => UserStake[]) public userStakes;
    /**
     * @notice 迁移授权映射。
     * @dev 结构为 mapping(migrator => mapping(user => isAuthorized))。
     *      记录某个迁移者地址是否被特定用户授权进行仓位迁移。
     */
    mapping(address migrator => mapping(address user => bool isAuthorized)) public migrationPermits;

    /**
     * @notice 合约构造函数。
     * @dev 初始化质押代币地址，授予初始角色，并配置默认管理员规则。
     * @param _admin 初始默认管理员地址，拥有管理所有角色的权限。
     * @param _manager 初始经理地址，拥有添加/更新质押周期、恢复代币等权限。
     * @param _pauser 初始暂停者地址，拥有暂停/恢复合约交易的权限。
     * @param _token 质押及奖励代币的地址。
     */
    constructor(address _admin, address _manager, address _pauser, address _token)
        // 初始化 AccessControlDefaultAdminRules：
        // 1. 设置默认管理员变更的延迟期为 1 天，增强安全性。
        // 2. 指定 _admin 为初始默认管理员。
        AccessControlDefaultAdminRules(1 days, _admin)
    {
        TOKEN = IERC20(_token);
        _grantRole(MANAGER_ROLE, _manager);
        _grantRole(PAUSER_ROLE, _pauser);
    }

    /**
     * @notice Stake tokens into a specific staking period.
     * @param periodIndex The index of the staking period to stake into.
     * @param amount The amount of tokens to stake.
     * @param params Additional staking parameters including max durations, min APR, and referrer.
     * @return stakeIndex The index of the newly created stake for the user.
     */
    function stake(uint8 periodIndex, uint256 amount, StakeParams calldata params)
        external
        nonReentrant
        whenNotPaused
        returns (uint8)
    {
        return _stake(periodIndex, amount, params);
    }

    /**
     * @notice Stake tokens using ERC20 Permit signature to approve transfer in the same transaction.
     * @param periodIndex The index of the staking period to stake into.
     * @param amount The amount of tokens to stake.
     * @param params Additional staking parameters including max durations, min APR, and referrer.
     * @param deadline The deadline for the permit signature.
     * @param v The recovery id of the signature.
     * @param r The r value of the signature.
     * @param s The s value of the signature.
     * @return stakeIndex The index of the newly created stake for the user.
     */
    function stakeWithPermit(
        uint8 periodIndex,
        uint256 amount,
        StakeParams calldata params,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint8) {
        // try catch for avoiding frontrun griefing
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/IERC20Permit.sol#L14
        // 如果token没有permit，比如weth怎么办？
        try IERC20Permit(address(TOKEN)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _stake(periodIndex, amount, params);
    }
    // user allowed to withdraw when contract is paused
    /**
     * @notice Withdraw claimed amounts and rewards from a specific stake.
     * @dev User is allowed to withdraw even when the contract is paused.
     * @param stakeIndex The index of the stake to withdraw from. 要提取的质押记录索引
     * @return totalWithdrawn The total amount of tokens withdrawn (principal + reward).
     */
    function withdraw(uint8 stakeIndex) external nonReentrant returns (uint256) {
        return _withdraw(stakeIndex);
    }

    /**
     * @notice 设置特定迁移者地址的迁移权限。
     * @dev 用户通过此函数授权特定的迁移合约（Migrator）可以操作其质押仓位。
     *      仅在状态发生变更时更新存储并触发事件，以节省 Gas。
     *      如果授权开启，会校验该地址是否拥有 MIGRATOR_ROLE，防止授权给无效地址。
     * @param _migrator 迁移者合约的地址。
     * @param _isMigrationPermitted true 表示允许迁移，false 表示撤销许可。
     */
    function setMigrationPermit(address _migrator, bool _isMigrationPermitted) external {
        // 如果当前权限状态与目标状态一致，则直接返回，避免不必要的存储写入和事件发射
        if (migrationPermits[_migrator][msg.sender] == _isMigrationPermitted) return;
        
        // 如果是开启权限，必须确保目标地址已被授予 MIGRATOR_ROLE，否则抛出异常
        if (_isMigrationPermitted && !hasRole(MIGRATOR_ROLE, _migrator)) revert MigratorNotFound(_migrator);

        // 更新迁移权限映射
        migrationPermits[_migrator][msg.sender] = _isMigrationPermitted;
        // 发射权限更新事件
        emit MigrationPermitUpdated(_migrator, msg.sender, _isMigrationPermitted);
    }

    /**
     * @notice 添加一个新的质押周期配置。
     * @dev 仅拥有 MANAGER_ROLE 的地址可调用。
     *      新添加的周期索引为当前数组长度。
     *      为了简化逻辑，此处不强制要求奖励为非零值，但通常 APR 应大于 0。
     * @param _cap 该周期允许的最大质押总量（容量）。
     * @param _stakingDurationSeconds 锁仓期时长（秒），在此期间本金不可提取。
     * @param _unlockDurationSeconds 解锁期时长（秒），在此期间本金和奖励线性释放。
     * @param _aprBps 年化收益率 (APR)，单位为基点 (bps)。例如：1000 = 10%。
     * @param _isActive 标识该周期是否立即激活以接受新的质押。
     * @return periodIndex 新添加的质押周期在数组中的索引。
     */
    function addStakingPeriod(
        uint256 _cap,
        uint64 _stakingDurationSeconds,
        uint64 _unlockDurationSeconds,
        uint32 _aprBps,
        bool _isActive
    ) external onlyRole(MANAGER_ROLE) returns (uint8) {
        // 校验锁仓期时长不能为 0
        if (_stakingDurationSeconds == 0) revert StakingDurationCannotBeZero();
        // 校验解锁期时长不能为 0
        if (_unlockDurationSeconds == 0) revert UnlockDurationCannotBeZero();
        // 校验质押周期数量不能超过 uint8 的最大值 (255)
        if (stakingPeriods.length > type(uint8).max) revert MaxStakingPeriodsReached();

        // 计算新周期的索引，即当前数组长度
        uint8 periodIndex = uint8(stakingPeriods.length);
        
        // 向数组末尾推送新的质押周期配置结构体
        stakingPeriods.push(
            StakingPeriod({
                cap: _cap,
                capUsed: 0, // 初始已用容量为 0
                stakingDurationSeconds: _stakingDurationSeconds,
                unlockDurationSeconds: _unlockDurationSeconds,
                aprBps: _aprBps,
                isActive: _isActive
            })
        );

        // 发射周期添加事件
        emit StakingPeriodAdded(periodIndex, _cap, _stakingDurationSeconds, _unlockDurationSeconds, _aprBps, _isActive);
        return periodIndex;
    }

    /**
     * @notice Update an existing staking period configuration.
     * @dev 仅拥有 MANAGER_ROLE 的地址可调用。
     *      允许修改容量、时长、APR 和激活状态。
     *      注意：允许将 cap 设置为低于当前已使用的值，但这不会强制退还超额部分，需管理员自行处理后续逻辑。
     * @param periodIndex The index of the staking period to update. 要更新的质押周期索引。
     * @param _cap The new maximum total amount that can be staked in this period. 新的最大质押容量。
     * @param _stakingDurationSeconds The new duration of the staking period in seconds. 新的锁仓期时长（秒）。
     * @param _unlockDurationSeconds The new duration of the unlock period in seconds. 新的解锁期时长（秒）。
     * @param _aprBps The new Annual Percentage Rate in basis points. 新的年化收益率 (bps)。
     * @param _isActive Whether the staking period is active for new stakes. 是否激活该周期以接受新质押。
     */
    function updateStakingPeriod(
        uint8 periodIndex,
        uint256 _cap,
        uint64 _stakingDurationSeconds,
        uint64 _unlockDurationSeconds,
        uint32 _aprBps,
        bool _isActive
    ) external onlyRole(MANAGER_ROLE) {
        // 校验锁仓期时长不能为 0
        if (_stakingDurationSeconds == 0) revert StakingDurationCannotBeZero();
        // 校验解锁期时长不能为 0
        if (_unlockDurationSeconds == 0) revert UnlockDurationCannotBeZero();
        // 校验周期索引必须存在
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();
        
        StakingPeriod storage stakingPeriod = stakingPeriods[periodIndex];

        // we allow to set cap lower than is currently being used
        // 更新质押周期的各项配置参数
        stakingPeriod.cap = _cap;
        stakingPeriod.stakingDurationSeconds = _stakingDurationSeconds;
        stakingPeriod.unlockDurationSeconds = _unlockDurationSeconds;
        stakingPeriod.aprBps = _aprBps;
        stakingPeriod.isActive = _isActive;

        // 发射周期更新事件
        emit StakingPeriodUpdated(
            periodIndex, _cap, _stakingDurationSeconds, _unlockDurationSeconds, _aprBps, _isActive
        );
    }

    /**
     * @notice Pause all staking operations. Only callable by PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all staking operations. Only callable by PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
    *     @dev manager allowed to recover full amount of any ERC20 token accidentally sent to staking contract
     *          except staking token itself. In case of staking token - manager allowed to recover only
     *          extra amount (which is not supposed to be distributed to users)
     * @notice Recover accidentally sent ERC20 tokens.
     * @dev Manager can recover full amount of any ERC20 token except the staking token.
     *      For the staking token, only the excess balance (not required for user stakes/rewards) can be recovered.
     * @param tokenAddress The address of the token to recover.
     * @param tokenAmount The amount of tokens to recover.
     */
    /**
     * @notice 恢复意外发送到质押合约的 ERC20 代币。
     * @dev 管理员可以恢复除质押代币本身以外的任何 ERC20 代币的全部数量。
     *      对于质押代币，仅能恢复超额部分（即不需要分配给用户的余额）。
     * @param tokenAddress 要恢复的代币地址。
     * @param tokenAmount 要恢复的代币数量。
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external nonReentrant onlyRole(MANAGER_ROLE) {
        if (tokenAddress == address(TOKEN)) {
            // 计算维持当前所有活跃质押和奖励所需的最低余额
            uint256 requiredBalance = activeTotalStaked + activeTotalRewards;
            // 获取合约当前的代币余额
            uint256 contractTokenBalance = TOKEN.balanceOf(address(this));
            // 如果当前余额不足以覆盖所需余额加上要恢复的数量，则抛出异常
            if (contractTokenBalance < requiredBalance + tokenAmount) {
                // invariant contractTokenBalance >= requiredBalance so can't underflow
                revert NotEnoughBalanceToRecover(tokenAddress, tokenAmount, contractTokenBalance - requiredBalance);
            }
        }

        emit Recovered(tokenAddress, msg.sender, tokenAmount);
        // 从staking合约转移到管理员
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
    }

    /**
     * @notice Migrate user stakes from V1 to V2 (or another contract).
     * @dev Fully withdrawn stakes are not getting migrated. This function transfers unclaimed principal and rewards
     *      to the migrator contract and returns the array of migrated stakes.
     * @param user The address of the user whose positions are being migrated.
     * @return migratedStakes An array of UserStake structs representing the migrated positions.
     */
    /**
     * @notice 将用户仓位从 V1 迁移到 V2（或其他合约）。
     * @dev 完全提取过的仓位不会被迁移。此函数将未领取的本金和奖励转移到迁移者合约，
     *      并返回已迁移仓位的数组。
     * @param user 正在迁移其仓位的用户地址。
     * @return migratedStakes 代表已迁移仓位的 UserStake 结构体数组。
     */
    //  q  有双花攻击吗？当迁移者被授权迁移用户仓位时，用户可以发起提币请求，那么在用户就可以在两个合约中提币了
    //  @audit high 不知道算不算，因为可能在socpe之外，而且用户这样就可以不等待，就可以在迁移合约中提币。
    function migratePositionsFrom(address user)
        external
        nonReentrant
        onlyRole(MIGRATOR_ROLE)
        returns (UserStake[] memory)
    {
        // 检查调用者是否被该用户授权进行迁移
        if (!migrationPermits[msg.sender][user]) revert MigratorNotPermitted(msg.sender, user);

        UserStake[] memory stakes = userStakes[user];
        uint256 stakesToMigrateCount;
        // Count migratedStakes array size
        // 统计需要迁移的仓位数量（即未完全提取的仓位）
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].claimedAmount + stakes[i].claimedReward < stakes[i].amount + stakes[i].reward) {
                stakesToMigrateCount++;
            }
        }
        // 创建用于存储已迁移仓位的数组
        UserStake[] memory migratedStakes = new UserStake[](stakesToMigrateCount);
        // 删除用户在原合约中的质押记录
        delete userStakes[user];

        uint8 migratedCount;
        uint256 unclaimedUserAmount;
        uint256 unclaimedUserRewards;
        // 遍历用户的所有仓位，收集未提取的本金和奖励，并填充迁移数组
        for (uint256 i = 0; i < stakes.length; i++) {
            // 如果仓位已完全提取，则跳过
            if (stakes[i].claimedAmount + stakes[i].claimedReward >= stakes[i].amount + stakes[i].reward) {
                continue;
            }
            // 累加未提取的本金
            unclaimedUserAmount += stakes[i].amount - stakes[i].claimedAmount;
            // 累加未提取的奖励
            unclaimedUserRewards += stakes[i].reward - stakes[i].claimedReward;

            migratedStakes[migratedCount] = stakes[i];
            migratedCount++;
        }

        // The capUsed is intentionally not decremented for migrated positions. Migration is a terminal operation:
        // the manager will deactivate all staking periods or pauser will pause the contract before migration begins
        // 从全局活跃质押总量中减去已迁移的未提取本金
        activeTotalStaked -= unclaimedUserAmount;
        // 从全局活跃奖励总量中减去已迁移的未提取奖励
        activeTotalRewards -= unclaimedUserRewards;

        emit MigratedFrom(msg.sender, user, migratedCount, unclaimedUserAmount, unclaimedUserRewards);
        // 将未提取的本金和奖励总额转账给迁移者合约
        TOKEN.safeTransfer(msg.sender, unclaimedUserAmount + unclaimedUserRewards);
        return migratedStakes;
    }

    /**
     * @notice Get all configured staking periods.
     * @return An array of all StakingPeriod structs.
     */
    function getStakingPeriods() external view returns (StakingPeriod[] memory) {
        return stakingPeriods;
    }

    /**
     * @notice Get a specific staking period by index.
     * @param periodIndex The index of the staking period.
     * @return The StakingPeriod struct at the given index.
     */
    function getStakingPeriod(uint8 periodIndex) external view returns (StakingPeriod memory) {
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();
        return stakingPeriods[periodIndex];
    }

    /**
     * @notice Get all stakes for a specific user.
     * @param user The address of the user.
     * @return An array of UserStake structs for the user.
     */
    function getUserStakes(address user) external view returns (UserStake[] memory) {
        return userStakes[user];
    }

    /**
     * @notice Get a specific stake for a user by index.
     * @param user The address of the user.
     * @param stakeIndex The index of the stake.
     * @return The UserStake struct at the given index.
     */
    function getUserStake(address user, uint8 stakeIndex) external view returns (UserStake memory) {
        if (stakeIndex >= userStakes[user].length) revert StakeNotFound();
        return userStakes[user][stakeIndex];
    }

    /**
     * @notice Calculate the claimable amount (principal + reward) for a specific stake.
     * @param user The address of the user.
     * @param stakeIndex The index of the stake.
     * @return The total claimable amount.
     */
    function getClaimable(address user, uint8 stakeIndex) external view returns (uint256) {
        if (stakeIndex >= userStakes[user].length) revert StakeNotFound();

        UserStake memory userStake = userStakes[user][stakeIndex];
        if (block.timestamp <= userStake.unlockTime) return 0;

        (uint256 amountToClaim, uint256 rewardToClaim) = _getClaimableAmounts(userStake);
        return amountToClaim + rewardToClaim;
    }

    function paused() public view virtual override(IStakingV1, Pausable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice 检查合约是否支持指定的接口。
     * @dev 实现 ERC165 标准，用于接口检测。
     *      支持 IMigratorV1 和 IStakingV1 接口，以及父类支持的接口。
     * @param interfaceId 要检查的接口标识符。
     * @return 如果支持该接口返回 true，否则返回 false。
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlDefaultAdminRules, IERC165)
        returns (bool)
    {
        return interfaceId == type(IMigratorV1).interfaceId || interfaceId == type(IStakingV1).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _stake(uint8 periodIndex, uint256 amount, StakeParams calldata params) internal returns (uint8) {
        // 1. 基础校验：质押数量不能为0，周期索引必须有效
        // q 如果amount太小，可能导致没有奖励，特别是wire erc20代币 6位的
        // 最好是整数倍，避免损失
        if (amount == 0) revert CannotStakeZero();
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();

        StakingPeriod storage stakingPeriod = stakingPeriods[periodIndex];
        // 2. 状态校验：指定的质押周期必须处于激活状态
        if (!stakingPeriod.isActive) revert StakingPeriodInactive(periodIndex);

        // 3. 防夹击校验：确保用户传入的参数限制（最大时长、最小APR）仍满足当前周期的配置
        // 防止在交易打包前周期参数被恶意修改导致用户利益受损
        // 保证周期参数满足用户要求
        if (stakingPeriod.stakingDurationSeconds > params.maxStakingDurationSeconds) {
            revert StakingPeriodStakingDurationDiffer(
                periodIndex, params.maxStakingDurationSeconds, stakingPeriod.stakingDurationSeconds
            );
        }
        if (stakingPeriod.unlockDurationSeconds > params.maxUnlockDurationSeconds) {
            revert StakingPeriodUnlockDurationDiffer(
                periodIndex, params.maxUnlockDurationSeconds, stakingPeriod.unlockDurationSeconds
            );
        }
        if (stakingPeriod.aprBps < params.minAprBps) {
            revert StakingPeriodAprDiffer(periodIndex, params.minAprBps, stakingPeriod.aprBps);
        }

        // 4. 容量校验：更新已用容量，确保不超过周期总上限
        uint256 updatedCapUsed = stakingPeriod.capUsed + amount;
        if (stakingPeriod.cap < updatedCapUsed) revert StakingCapReached(stakingPeriod.cap);
        // 5. 用户限制校验：确保用户当前的质押位置数量未超过上限
        if (userStakes[msg.sender].length >= MAX_STAKES_PER_USER) revert MaxUserStakesReached(MAX_STAKES_PER_USER);

        // 6. 奖励计算：根据本金、APR和质押时长计算预期奖励
        // 默认一年是365
        // reward = (amount * aprBps * stakingDurationSeconds) / (10_000 * 365 days)
        uint256 rewardBpsDenominator = 1e4 * 365 days;
        uint256 reward = (amount * stakingPeriod.aprBps * stakingPeriod.stakingDurationSeconds) / rewardBpsDenominator;
        
        // 7. 偿付能力校验：确保合约当前余额足以支付新增的奖励承诺
        uint256 contractBalance = TOKEN.balanceOf(address(this));
        uint256 requiredBalance = activeTotalStaked + activeTotalRewards + reward;
        if (requiredBalance > contractBalance) {
            revert NotEnoughContractBalance(address(TOKEN), contractBalance, requiredBalance);
        }

        // 8. 状态更新：增加全局质押总量、奖励总量以及周期已用容量
        activeTotalStaked += amount;
        activeTotalRewards += reward;
        stakingPeriod.capUsed = updatedCapUsed;

        // 9. 创建质押记录：生成新的 UserStake 结构体并存入用户映射
        uint8 stakeIndex = uint8(userStakes[msg.sender].length);
        userStakes[msg.sender].push(
            UserStake({
                amount: amount,
                reward: reward,
                claimedAmount: 0,
                claimedReward: 0,
                aprBps: stakingPeriod.aprBps,
                stakeTime: uint64(block.timestamp),
                unlockTime: uint64(block.timestamp) + stakingPeriod.stakingDurationSeconds,
                unlockDuration: stakingPeriod.unlockDurationSeconds
            })
        );

        // 10. 事件发射与资金转移：记录质押事件并从用户账户转移代币到合约
        emit Staked(msg.sender, periodIndex, params.referrer, stakeIndex, amount, reward);
        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        return stakeIndex;
    }

     function getactiveTotalStaked() external view returns (uint256){
        return activeTotalStaked;   
     }

    /**
     * @notice 获取当前所有活跃质押的预期奖励总和。
     * @return 活跃质押奖励总量。
     */
    function getactiveTotalRewards() external view returns (uint256){
            return activeTotalRewards;
     }
    /**
     * @notice 执行质押提现操作，支持线性解锁机制。
     * @dev 用户在质押期结束并进入解锁期后，可以分多次提取本金和奖励。
     *      提取金额根据线性解锁公式计算，即使合约处于暂停状态也允许用户提取。
     * @param stakeIndex 用户要提取的质押记录的索引。
     * @return totalToWithdraw 本次提取的总金额（包含本金和奖励）。
     */
    function _withdraw(uint8 stakeIndex) internal returns (uint256) {
        // 1. 索引校验：确保请求提取的质押索引存在
        if (stakeIndex >= userStakes[msg.sender].length) revert StakeNotFound();

        UserStake storage userStake = userStakes[msg.sender][stakeIndex];
        // 2. 时间校验：当前时间必须大于解锁开始时间（即质押结束时间）
        if (block.timestamp <= userStake.unlockTime) {
            revert RewardsNotAvailableYet(uint64(block.timestamp), userStake.unlockTime);
        }
        // 3. 状态校验：确保该质押尚未完全提取完毕
        if (userStake.claimedAmount + userStake.claimedReward >= userStake.amount + userStake.reward) {
            revert AlreadyWithdrawn(stakeIndex);
        }

        // 4. 计算可提取金额：根据线性解锁机制计算当前可提取的本金和奖励
        // 按时间比例线性解锁
        (uint256 amountToClaim, uint256 rewardToClaim) = _getClaimableAmounts(userStake);
        uint256 totalToWithdraw = amountToClaim + rewardToClaim;

        // 5. 状态更新：减少全局质押总量和奖励总量，增加用户已提取记录
        activeTotalStaked -= amountToClaim;
        activeTotalRewards -= rewardToClaim;
        userStake.claimedAmount += amountToClaim;
        userStake.claimedReward += rewardToClaim;

        // 6. 事件发射与资金转移：记录提取事件并将代币发送给用户
        emit Withdrawn(msg.sender, stakeIndex, amountToClaim, rewardToClaim);
        TOKEN.safeTransfer(msg.sender, totalToWithdraw);
        return totalToWithdraw;
    }

    function _getAccrued(uint256 amount, uint256 duration, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(amount, Math.min(elapsed, duration), duration);
    }

    /**
     * @notice 计算指定质押记录中当前可提取的本金和奖励金额。
     * @dev 基于线性解锁机制，根据当前时间与解锁进度的关系计算累积量，
     *      并减去用户已提取的部分，得出净可提取量。
     * @param userStake 用户的质押记录结构体。
     * @return claimableAmount 当前可提取的本金金额。
     * @return claimableReward 当前可提取的奖励金额。
     */
    function _getClaimableAmounts(UserStake memory userStake)
        internal
        view
        returns (uint256 claimableAmount, uint256 claimableReward)
    {
        // 1. 计算经过的时间：从解锁开始时间（质押结束时间）到当前时间的时长
        uint256 elapsed = block.timestamp - userStake.unlockTime;
        
        // 2. 计算线性累积量：根据经过时间和解锁总时长，计算应累积的本金和奖励比例
        // _getAccrued 会处理 elapsed 超过 duration 的情况（即完全解锁）
        uint256 accruedAmount = _getAccrued(userStake.amount, userStake.unlockDuration, elapsed);
        uint256 accruedReward = _getAccrued(userStake.reward, userStake.unlockDuration, elapsed);

        // 3. 计算净可提取量：从累积总量中减去用户已经提取的部分，得到本次可提取的差额
        claimableAmount = accruedAmount - userStake.claimedAmount;
        claimableReward = accruedReward - userStake.claimedReward;
    }
}
