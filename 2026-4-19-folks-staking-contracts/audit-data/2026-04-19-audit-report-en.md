## Medium

### [M-1] `capUsed` Only Increases, Never Decreases – Leading to Permanent Capacity Lock and Potential DoS

**Description**  
`capUsed` is only incremented when a user stakes. It is never decremented during withdrawals. As a result, once a staking period reaches its `cap` (i.e., `capUsed == cap`), no further stakes can be accepted into that period – even if all users later withdraw their funds. Combined with the hard limit of 256 staking periods (`type(uint8).max`), a malicious actor could sequentially fill every period’s capacity, permanently blocking new stakes for legitimate users.

```javascript
if (stakingPeriods.length > type(uint8).max) revert MaxStakingPeriodsReached();
```

**Impact**  
While the original finding considered this an economic design flaw, the attack path described below elevates the severity to **DoS**:

1. A `MANAGER_ROLE` can add new staking periods (up to 256).
2. An attacker monitors for newly added active periods and stakes the full remaining capacity (`cap - capUsed`) in each one.
3. The attacker can later withdraw their funds, but `capUsed` remains unchanged – the period stays “full” forever.
4. By repeating this across all 256 periods, the attacker makes the entire staking contract unusable for new deposits.

It seems that there are no managers or owners who can transfer funds out of pledge or suspend withdrawals. This means the attacker faces no financial risk (they can always withdraw their principal) and there is no emergency intervention to recover capacity – the DoS is permanent and irreversible.

What’s worse, although the manager can call `updateStakingPeriod` to adjust period parameters (e.g., lower the `cap` or deactivate the period), an attacker can still front-run and fill the period’s capacity after the manager’s modification takes effect.



**Proof of Concept**  
- Manager adds a staking period with `cap = 100,000 tokens`.  
- Attacker stakes 100,000 tokens → `capUsed = 100,000`.  
- Attacker waits for the unlock period, then withdraws everything.  
- `capUsed` remains 100,000, so no new user can ever stake into that period.  
- The attacker repeats this for all 256 periods, exhausting the entire staking infrastructure.

**Recommended Mitigation**  
Introduce a mechanism to decrease `capUsed` proportionally when users withdraw:

Store `periodIndex` in `UserStake`. In `_withdraw`, compute the reduction as  
  `(stakingPeriod.capUsed * amountToClaim) / userStake.amount` and subtract it from `capUsed`.  


---

## Informational

### [I-1] Uninitialized Local Variables

**Description**  
In `Staking.sol`, several local variables are declared without explicit initialization:

```solidity
uint8 migratedCount;
uint256 unclaimedUserAmount;
uint256 unclaimedUserRewards;
uint256 stakesToMigrateCount;
```

While Solidity defaults uninitialized values to zero, relying on this implicit behavior reduces code clarity and may lead to subtle bugs if the code is refactored later.

**Recommended Mitigation**  
Explicitly initialize all local variables to zero (or their intended default values):

```solidity
uint8 migratedCount = 0;
uint256 unclaimedUserAmount = 0;
uint256 unclaimedUserRewards = 0;
uint256 stakesToMigrateCount = 0;
```

This improves readability and aligns with defensive coding practices.


### [I-2] Very Small Deposits May Yield Zero Rewards

**Description**  
The reward calculation uses integer division:

```solidity
reward = (amount * aprBps * stakingDurationSeconds) / (10_000 * 365 days);
```

Because Solidity rounds down, if the product `amount * aprBps * stakingDurationSeconds` is smaller than the denominator, `reward` becomes zero. For example, with a typical APR of 10% (`aprBps = 1000`) and a 30-day staking duration, the minimum `amount` required to get a non-zero reward is:

```
minAmount = (10_000 * 365 days) / (1000 * 30 days) ≈ 121.67 tokens
```

If a user stakes less than this threshold, they will receive no reward at all – though their principal remains safe.

**Impact**  
- Users might stake expecting a small reward but receive nothing, leading to confusion or dissatisfaction.  
- Not a security vulnerability, but an economic edge case that should be communicated clearly.

**Recommended Mitigation**  
- **Front-end / UI**: Compute the minimum deposit amount for each staking period (using the formula above) and display it prominently. Prevent or warn users when their deposit would yield zero reward.  
- **Contract (optional)**: Add a check `if (reward == 0) revert RewardIsZero();` – however, this would block micro-deposits entirely, which may be undesirable for users who only care about principal safety. A warning-only approach is recommended.  
