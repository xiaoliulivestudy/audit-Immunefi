// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.30;

import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IStakingV1} from "./IStakingV1.sol";

/**
 *     @dev Migrator require permission from user to transfer their position to the new staking contract.
 *          (migrator should not be able to migrate stakes if not approved by user)
 */
//  继承IMigratorV1接口的合约是FROM，或者说就是stakingv1
// ok
interface IMigratorV1 is IERC165, IStakingV1 {
    function setMigrationPermit(address _migrator, bool _isMigrationPermitted) external;
    function migratePositionsFrom(address user) external returns (UserStake[] memory);
}
