// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title YugeAI
 * @notice Kettle corn allocation ledger with claw-style grab slots and big-league deal rails.
 *        Tracks golden epochs, covfefe oracles, and treasury sweeps per EIP-2847-style batch slots.
 * @dev Deploy with default role addresses; mainnet-safe guards: role checks, non-reentrant mutators, bounded loops.
 *
 * Epochs are fixed-duration windows; grab intensity is stored in basis points. Slot sealing is commander-only.
 * Covfefe oracle updates are rate-limited by block cooldown. Treasury sweep cap is immutable at deploy.
 * All role addresses are set in constructor and cannot be changed. Use setKeeperAuthorization to add/remove
 * keepers for logGrab and reserveSlot. Deal lifecycle: openDeal (dealMaker) then closeDeal (dealMaker) to pay party.
 * Big-league claims are one-time rewards set by commander via setClaimReward; claimBigLeague pays msg.sender.
 * Vault deposits accumulate in _vaultBalanceWei; withdrawVault and distributeGoldenEpochReward are commander-only.
 * Epoch snapshots aggregate grab counts and intensity sum for an epoch and are recorded once per epoch by commander.
 */

// -----------------------------------------------------------------------------
// Constants and configuration (do not modify post-deploy; role addresses are immutable)
// -----------------------------------------------------------------------------

bytes32 constant YUGEAI_NAMESPACE_SALT = 0x3c7e2a9f1b4d6e8f0a2c4b6d8e0f2a4c6b8d0e2f4a6c8b0d2e4f6a8c0e2b4d6e8;

uint256 constant YUGEAI_BPS = 10_000;
uint256 constant YUGEAI_GOLDEN_EPOCH_REWARD_BPS = 250;
uint256 constant YUGEAI_VAULT_FEE_BPS = 35;
uint256 constant YUGEAI_MAX_BATCH_GRABS = 47;
uint256 constant YUGEAI_MAX_BATCH_SLOTS = 23;
uint256 constant YUGEAI_EPOCH_SNAPSHOT_CAP = 5000;
uint256 constant YUGEAI_WINNING_INTENSITY_THRESHOLD_BPS = 5000;
uint256 constant YUGEAI_MAX_GRABS_PER_EPOCH = 777;
uint256 constant YUGEAI_EPOCH_DURATION_SECS = 14_400;
uint256 constant YUGEAI_TREASURY_SWEEP_CAP_WEI = 17 ether;
uint256 constant YUGEAI_MAX_DEAL_SLOTS = 99_999;
uint256 constant YUGEAI_MIN_GRAB_BPS = 100;
uint256 constant YUGEAI_MAX_GRAB_BPS = 9500;
uint256 constant YUGEAI_ORACLE_COOLDOWN_BLOCKS = 12;
uint256 constant YUGEAI_LOCK_FLAG = 1;
uint256 constant YUGEAI_PROTOCOL_REV = 7;

error YugeAI_NotCommander();
error YugeAI_NotTreasury();
error YugeAI_NotOracle();
error YugeAI_NotDealMaker();
error YugeAI_GuardPaused();
error YugeAI_Reentrant();
error YugeAI_InvalidGrabId();
error YugeAI_GrabAlreadyFinalized();
error YugeAI_SweepOverCap();
error YugeAI_ZeroAmount();
error YugeAI_InvalidSlot();
error YugeAI_SlotAlreadySealed();
error YugeAI_BadInput();
error YugeAI_LimitReached();
error YugeAI_OracleCooldown();
error YugeAI_InvalidAddress();
error YugeAI_DealNotActive();
error YugeAI_Unauthorized();

event GrabLogged(uint256 indexed grabId, uint256 intensityBps, uint40 loggedAt, address indexed keeper);
event DealExecuted(uint256 indexed dealId, address indexed party, uint256 amountWei, uint64 atBlock);
event SlotSealed(uint256 indexed slotIndex, uint64 variantId, uint88 bandBps, uint40 sealedAt);
event TreasurySwept(address indexed to, uint256 amountWei);
event GuardToggled(bool paused);
event OraclePulse(bytes32 indexed feedId, int256 value, uint64 atBlock);
event BigLeagueClaim(address indexed claimant, uint256 claimIndex, uint256 rewardWei);
event CovfefeUpdated(bytes32 indexed key, bytes32 value, uint64 atBlock);
event KeeperAuthorized(address indexed keeper, bool authorized);
event EpochSnapshotRecorded(uint256 indexed epochId, uint256 totalGrabs, uint256 sumIntensityBps);
event VaultDeposit(address indexed from, uint256 amountWei, uint64 atBlock);
event VaultWithdraw(address indexed to, uint256 amountWei, uint64 atBlock);
event GoldenEpochReward(uint256 indexed epochId, address indexed recipient, uint256 amountWei);
event BatchGrabsLogged(uint256 indexed startId, uint256 count, uint64 atBlock);

struct GrabRecord {
    uint88 intensityBps;
    uint40 loggedAt;
    uint64 epochId;
    bool finalized;
}

struct DealSlot {
    uint96 amountWei;
    uint64 createdAtBlock;
    uint64 closedAtBlock;
    address party;
    bool active;
    bool closed;
}

struct BatchSlot {
    uint88 bandBps;
    uint40 sealedAt;
    uint64 variantId;
    bool sealed;
}

struct EpochSnapshot {
    uint64 recordedAtBlock;
    uint32 totalGrabs;
    uint128 sumIntensityBps;
    bool recorded;
}

library YugeAIHelpers {
    function bpsToWei(uint256 weiTotal, uint256 bps) internal pure returns (uint256) {
        return (weiTotal * bps) / 10_000;
    }
    function clampIntensity(uint256 rawBps, uint256 minBps, uint256 maxBps) internal pure returns (uint88) {
        if (rawBps < minBps) return uint88(minBps);
        if (rawBps > maxBps) return uint88(maxBps);
        return uint88(rawBps);
    }
    function isWinningIntensity(uint256 intensityBps, uint256 thresholdBps) internal pure returns (bool) {
        return intensityBps >= thresholdBps;
    }
    function epochEndTime(uint256 genesisTime, uint256 epochId, uint256 durationSecs) internal pure returns (uint256) {
        return genesisTime + (epochId + 1) * durationSecs;
    }
    function epochStartSlot(uint256 epochId, uint256 maxPerEpoch) internal pure returns (uint256) {
        return epochId * maxPerEpoch;
    }
    function intensityInTier(uint8 tier) internal pure returns (uint256 minBps, uint256 maxBps) {
        if (tier == 0) return (0, 999);
        if (tier == 1) return (1000, 4999);
        if (tier == 2) return (5000, 7999);
        return (8000, 10000);
    }
    function tierFromIntensity(uint256 intensityBps) internal pure returns (uint8) {
        if (intensityBps >= 8000) return 3;
        if (intensityBps >= 5000) return 2;
        if (intensityBps >= 1000) return 1;
        return 0;
    }
    function safeAdd128(uint128 a, uint128 b) internal pure returns (uint128) {
        uint128 c = a + b;
        require(c >= a, "YugeAI: overflow");
        return c;
    }
    function minUint256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    function maxUint256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

contract YugeAI {
    address public immutable commander;
    address public immutable treasury;
    address public immutable covfefeOracle;
    address public immutable dealMaker;
    address public immutable vault;

    uint256 public immutable genesisTime;
    uint256 public immutable sweepCapWei;
    uint256 public immutable deployBlock;

    bool public guardPaused;
    uint256 private _reentrancyLock;
    uint256 private _nextGrabId;
    uint256 private _nextDealId;
    uint256 private _nextSlotIndex;
    uint256 private _nextClaimIndex;
    uint256 private _totalSweptWei;
    uint256 private _lastOracleBlock;
    uint256 private _currentEpoch;

    mapping(uint256 => GrabRecord) private _grabs;
    mapping(uint256 => DealSlot) private _deals;
    mapping(uint256 => BatchSlot) private _slots;
    mapping(address => uint256) private _claimCount;
    mapping(uint256 => uint256) private _claimRewardWei;
    mapping(address => bool) private _authorizedKeepers;
    mapping(bytes32 => bytes32) private _covfefeStore;
    mapping(bytes32 => uint64) private _covfefeUpdatedBlock;
    mapping(uint256 => EpochSnapshot) private _epochSnapshots;
    mapping(uint256 => uint256) private _epochGrabCount;
    uint256 private _vaultBalanceWei;

    modifier onlyCommander() {
        if (msg.sender != commander) revert YugeAI_NotCommander();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert YugeAI_NotTreasury();
        _;
    }
