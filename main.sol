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

    modifier onlyOracle() {
        if (msg.sender != covfefeOracle) revert YugeAI_NotOracle();
        _;
    }

    modifier onlyDealMaker() {
        if (msg.sender != dealMaker) revert YugeAI_NotDealMaker();
        _;
    }

    modifier whenNotPaused() {
        if (guardPaused) revert YugeAI_GuardPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert YugeAI_Reentrant();
        _reentrancyLock = YUGEAI_LOCK_FLAG;
        _;
        _reentrancyLock = 0;
    }

    /*
     * Epoch boundaries are inclusive start, exclusive end in terms of slot allocation.
     * Grabs are keyed by global id; epochId is stored per grab for analytics.
     * Deal slots are independent of epochs. Covfefe keys are arbitrary bytes32.
     * Oracle cooldown applies to both setCovfefe and pulseOracle in the same way.
     * Treasury sweep cap is fixed at deploy; vault balance is separate from general balance.
     * Golden epoch rewards are drawn from vault only and limited by YUGEAI_GOLDEN_EPOCH_REWARD_BPS.
     * Batch operations (batchLogGrabs, batchReserveSlots) enforce per-call limits to bound gas.
     * Slot sealing overwrites bandBps, sealedAt, variantId and sets sealed = true; reserveSlot only allocates.
     * Claim rewards are set by commander per claim index; claimant can claim once per index (reward zeroed after).
     * Reentrancy guard is applied on all state-changing external functions that touch balances or deal closure.
     */

    constructor() {
        commander = 0x7E2a4C6e8F0b2D4f6A8c0E2a4C6e8F0b2D4f6A8c0;
        treasury = 0x1B3d5F7a9C1e3B5d7F9a1C3e5B7d9F1a3C5e7B9d1;
        covfefeOracle = 0x9D1f3A5c7E9b1D3f5A7c9E1b3D5f7A9c1E3b5D7f9;
        dealMaker = 0x4F6a8C0e2A4f6A8c0E2a4F6a8C0e2A4f6A8c0E2a4;
        vault = 0xC2e4F6a8B0c2E4f6A8b0C2e4F6a8B0c2E4f6A8b0;

        genesisTime = block.timestamp;
        deployBlock = block.number;
        sweepCapWei = YUGEAI_TREASURY_SWEEP_CAP_WEI;
        guardPaused = false;
        _lastOracleBlock = 0;
        _currentEpoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        _authorizedKeepers[commander] = true;
    }

    function logGrab(uint256 intensityBps) external whenNotPaused returns (uint256 grabId) {
        if (!_authorizedKeepers[msg.sender]) revert YugeAI_Unauthorized();
        if (intensityBps < YUGEAI_MIN_GRAB_BPS || intensityBps > YUGEAI_MAX_GRAB_BPS) revert YugeAI_BadInput();
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        uint256 epochStartSlot = epoch * YUGEAI_MAX_GRABS_PER_EPOCH;
        if (_nextGrabId >= epochStartSlot + YUGEAI_MAX_GRABS_PER_EPOCH) revert YugeAI_LimitReached();

        grabId = _nextGrabId++;
        GrabRecord storage r = _grabs[grabId];
        r.intensityBps = uint88(intensityBps);
        r.loggedAt = uint40(block.timestamp);
        r.epochId = uint64(epoch);
        r.finalized = true;
        emit GrabLogged(grabId, r.intensityBps, r.loggedAt, msg.sender);
        return grabId;
    }

    function getGrab(uint256 grabId) external view returns (uint88 intensityBps, uint40 loggedAt, uint64 epochId, bool finalized) {
        GrabRecord storage r = _grabs[grabId];
        return (r.intensityBps, r.loggedAt, r.epochId, r.finalized);
    }

    function openDeal(address party, uint96 amountWei) external onlyDealMaker whenNotPaused nonReentrant returns (uint256 dealId) {
        if (party == address(0) || amountWei == 0) revert YugeAI_ZeroAmount();
        if (_nextDealId >= YUGEAI_MAX_DEAL_SLOTS) revert YugeAI_LimitReached();
        dealId = _nextDealId++;
        _deals[dealId] = DealSlot({
            amountWei: amountWei,
            createdAtBlock: uint64(block.number),
            closedAtBlock: 0,
            party: party,
            active: true,
            closed: false
        });
        emit DealExecuted(dealId, party, amountWei, uint64(block.number));
        return dealId;
    }

    function closeDeal(uint256 dealId) external onlyDealMaker nonReentrant {
        DealSlot storage d = _deals[dealId];
        if (!d.active || d.closed) revert YugeAI_DealNotActive();
        d.closed = true;
        d.closedAtBlock = uint64(block.number);
        (bool ok,) = d.party.call{ value: d.amountWei }("");
        require(ok, "YugeAI: transfer failed");
        emit DealExecuted(dealId, d.party, d.amountWei, uint64(block.number));
    }

    function getDeal(uint256 dealId) external view returns (
        uint96 amountWei,
        uint64 createdAtBlock,
        uint64 closedAtBlock,
        address party,
        bool active,
        bool closed
    ) {
        DealSlot storage d = _deals[dealId];
        return (d.amountWei, d.createdAtBlock, d.closedAtBlock, d.party, d.active, d.closed);
    }

    function sealSlot(uint256 slotIndex, uint64 variantId, uint88 bandBps) external onlyCommander {
        if (slotIndex >= _nextSlotIndex) revert YugeAI_InvalidSlot();
        BatchSlot storage s = _slots[slotIndex];
        if (s.sealed) revert YugeAI_SlotAlreadySealed();
        s.bandBps = bandBps;
        s.sealedAt = uint40(block.timestamp);
        s.variantId = variantId;
        s.sealed = true;
        emit SlotSealed(slotIndex, variantId, bandBps, s.sealedAt);
    }

    function reserveSlot() external returns (uint256 slotIndex) {
        if (!_authorizedKeepers[msg.sender]) revert YugeAI_Unauthorized();
        uint256 epochEnd = genesisTime + (_currentEpoch + 1) * YUGEAI_EPOCH_DURATION_SECS;
        if (block.timestamp >= epochEnd) _currentEpoch++;
        uint256 slotsUsed = _nextSlotIndex - _currentEpoch * YUGEAI_MAX_GRABS_PER_EPOCH;
        if (slotsUsed >= YUGEAI_MAX_GRABS_PER_EPOCH) {
            _currentEpoch++;
            slotsUsed = _nextSlotIndex - _currentEpoch * YUGEAI_MAX_GRABS_PER_EPOCH;
        }
        if (slotsUsed >= YUGEAI_MAX_GRABS_PER_EPOCH) revert YugeAI_InvalidSlot();
        slotIndex = _nextSlotIndex;
        _nextSlotIndex++;
        _slots[slotIndex] = BatchSlot({ bandBps: 0, sealedAt: 0, variantId: 0, sealed: false });
        return slotIndex;
    }

    function getSlot(uint256 slotIndex) external view returns (uint88 bandBps, uint40 sealedAt, uint64 variantId, bool sealed) {
        BatchSlot storage s = _slots[slotIndex];
        return (s.bandBps, s.sealedAt, s.variantId, s.sealed);
    }

    function setCovfefe(bytes32 key, bytes32 value) external onlyOracle {
        if (block.number < _lastOracleBlock + YUGEAI_ORACLE_COOLDOWN_BLOCKS) revert YugeAI_OracleCooldown();
        _lastOracleBlock = block.number;
        _covfefeStore[key] = value;
        _covfefeUpdatedBlock[key] = uint64(block.number);
        emit CovfefeUpdated(key, value, uint64(block.number));
    }

    function pulseOracle(bytes32 feedId, int256 value) external onlyOracle {
        if (block.number < _lastOracleBlock + YUGEAI_ORACLE_COOLDOWN_BLOCKS) revert YugeAI_OracleCooldown();
        _lastOracleBlock = block.number;
        emit OraclePulse(feedId, value, uint64(block.number));
    }

    function getCovfefe(bytes32 key) external view returns (bytes32 value, uint64 updatedBlock) {
        return (_covfefeStore[key], _covfefeUpdatedBlock[key]);
    }

    function claimBigLeague(uint256 claimIndex) external whenNotPaused nonReentrant {
        uint256 reward = _claimRewardWei[claimIndex];
        if (reward == 0) revert YugeAI_InvalidGrabId();
        _claimRewardWei[claimIndex] = 0;
        _claimCount[msg.sender]++;
        (bool ok,) = msg.sender.call{ value: reward }("");
        require(ok, "YugeAI: claim transfer failed");
        emit BigLeagueClaim(msg.sender, claimIndex, reward);
    }

    function setClaimReward(uint256 claimIndex, uint256 rewardWei) external onlyCommander {
        _claimRewardWei[claimIndex] = rewardWei;
    }

    function sweepTreasury(address to, uint256 amountWei) external onlyTreasury nonReentrant {
        if (to == address(0) || amountWei == 0) revert YugeAI_ZeroAmount();
        if (_totalSweptWei + amountWei > sweepCapWei) revert YugeAI_SweepOverCap();
        _totalSweptWei += amountWei;
        (bool ok,) = to.call{ value: amountWei }("");
        require(ok, "YugeAI: sweep failed");
        emit TreasurySwept(to, amountWei);
    }

    function setGuardPaused(bool paused) external onlyCommander {
        guardPaused = paused;
        emit GuardToggled(paused);
    }

    function setKeeperAuthorization(address keeper, bool authorized) external onlyCommander {
        if (keeper == address(0)) revert YugeAI_InvalidAddress();
        _authorizedKeepers[keeper] = authorized;
        emit KeeperAuthorized(keeper, authorized);
    }

    function totalSweptWei() external view returns (uint256) {
        return _totalSweptWei;
    }

    function claimCount(address account) external view returns (uint256) {
        return _claimCount[account];
    }

    function isKeeperAuthorized(address account) external view returns (bool) {
        return _authorizedKeepers[account];
    }

    function nextGrabId() external view returns (uint256) {
        return _nextGrabId;
    }

    function nextDealId() external view returns (uint256) {
        return _nextDealId;
    }

    function nextSlotIndex() external view returns (uint256) {
        return _nextSlotIndex;
    }

    function currentEpochIndex() external view returns (uint256) {
        return (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
    }

    function lastOracleBlock() external view returns (uint256) {
        return _lastOracleBlock;
    }

    function batchLogGrabs(uint256[] calldata intensityBpsList) external whenNotPaused returns (uint256 firstId, uint256 count) {
        if (!_authorizedKeepers[msg.sender]) revert YugeAI_Unauthorized();
        if (intensityBpsList.length == 0 || intensityBpsList.length > YUGEAI_MAX_BATCH_GRABS) revert YugeAI_BadInput();
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        uint256 epochStartSlot = YugeAIHelpers.epochStartSlot(epoch, YUGEAI_MAX_GRABS_PER_EPOCH);
        if (_nextGrabId + intensityBpsList.length > epochStartSlot + YUGEAI_MAX_GRABS_PER_EPOCH) revert YugeAI_LimitReached();
        firstId = _nextGrabId;
        for (uint256 i = 0; i < intensityBpsList.length; i++) {
            uint256 intensityBps = intensityBpsList[i];
            if (intensityBps < YUGEAI_MIN_GRAB_BPS || intensityBps > YUGEAI_MAX_GRAB_BPS) revert YugeAI_BadInput();
            uint256 grabId = _nextGrabId++;
            GrabRecord storage r = _grabs[grabId];
            r.intensityBps = YugeAIHelpers.clampIntensity(intensityBps, YUGEAI_MIN_GRAB_BPS, YUGEAI_MAX_GRAB_BPS);
            r.loggedAt = uint40(block.timestamp);
            r.epochId = uint64(epoch);
            r.finalized = true;
            emit GrabLogged(grabId, r.intensityBps, r.loggedAt, msg.sender);
        }
        count = intensityBpsList.length;
        _epochGrabCount[epoch] += count;
        emit BatchGrabsLogged(firstId, count, uint64(block.number));
        return (firstId, count);
    }

    function recordEpochSnapshot(uint256 epochId) external onlyCommander returns (bool) {
        if (epochId >= (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS) revert YugeAI_BadInput();
        if (_epochSnapshots[epochId].recorded) revert YugeAI_SlotAlreadySealed();
        if (epochId >= YUGEAI_EPOCH_SNAPSHOT_CAP) revert YugeAI_LimitReached();
        uint256 startSlot = epochId * YUGEAI_MAX_GRABS_PER_EPOCH;
        uint256 endSlot = startSlot + YUGEAI_MAX_GRABS_PER_EPOCH;
        uint32 totalGrabs = 0;
        uint128 sumBps = 0;
        for (uint256 id = startSlot; id < endSlot && id < _nextGrabId; id++) {
            GrabRecord storage r = _grabs[id];
            if (r.loggedAt != 0) {
                totalGrabs++;
                sumBps += r.intensityBps;
            }
        }
        _epochSnapshots[epochId] = EpochSnapshot({
            recordedAtBlock: uint64(block.number),
            totalGrabs: totalGrabs,
            sumIntensityBps: sumBps,
            recorded: true
        });
        emit EpochSnapshotRecorded(epochId, totalGrabs, sumBps);
        return true;
    }

    function getEpochSnapshot(uint256 epochId) external view returns (uint64 recordedAtBlock, uint32 totalGrabs, uint128 sumIntensityBps, bool recorded) {
        EpochSnapshot storage s = _epochSnapshots[epochId];
        return (s.recordedAtBlock, s.totalGrabs, s.sumIntensityBps, s.recorded);
    }

    function depositVault() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert YugeAI_ZeroAmount();
        _vaultBalanceWei += msg.value;
        emit VaultDeposit(msg.sender, msg.value, uint64(block.number));
    }

    function withdrawVault(address to, uint256 amountWei) external onlyCommander nonReentrant {
        if (to == address(0) || amountWei == 0) revert YugeAI_ZeroAmount();
        if (amountWei > _vaultBalanceWei) revert YugeAI_SweepOverCap();
        _vaultBalanceWei -= amountWei;
        (bool ok,) = to.call{ value: amountWei }("");
        require(ok, "YugeAI: vault withdraw failed");
        emit VaultWithdraw(to, amountWei, uint64(block.number));
    }

    function vaultBalance() external view returns (uint256) {
        return _vaultBalanceWei;
    }

    function distributeGoldenEpochReward(uint256 epochId, address recipient, uint256 amountWei) external onlyCommander nonReentrant {
        if (recipient == address(0) || amountWei == 0) revert YugeAI_ZeroAmount();
        EpochSnapshot storage s = _epochSnapshots[epochId];
        if (!s.recorded) revert YugeAI_BadInput();
        uint256 maxReward = YugeAIHelpers.bpsToWei(_vaultBalanceWei, YUGEAI_GOLDEN_EPOCH_REWARD_BPS);
        if (amountWei > maxReward) revert YugeAI_SweepOverCap();
        _vaultBalanceWei -= amountWei;
        (bool ok,) = recipient.call{ value: amountWei }("");
        require(ok, "YugeAI: golden reward transfer failed");
        emit GoldenEpochReward(epochId, recipient, amountWei);
    }

    function getGrabsBatch(uint256 fromId, uint256 limit) external view returns (
        uint256[] memory grabIds,
        uint88[] memory intensityBpsList,
        uint40[] memory loggedAtList,
        uint64[] memory epochIds,
        bool[] memory finalizedList
    ) {
        uint256 cap = limit > 101 ? 101 : limit;
        grabIds = new uint256[](cap);
        intensityBpsList = new uint88[](cap);
        loggedAtList = new uint40[](cap);
        epochIds = new uint64[](cap);
        finalizedList = new bool[](cap);
        uint256 written = 0;
        for (uint256 id = fromId; id < _nextGrabId && written < cap; id++) {
            GrabRecord storage r = _grabs[id];
            if (r.loggedAt != 0) {
                grabIds[written] = id;
                intensityBpsList[written] = r.intensityBps;
                loggedAtList[written] = r.loggedAt;
                epochIds[written] = r.epochId;
                finalizedList[written] = r.finalized;
                written++;
            }
        }
        if (written < cap) {
            assembly {
                mstore(grabIds, written)
                mstore(intensityBpsList, written)
                mstore(loggedAtList, written)
                mstore(epochIds, written)
                mstore(finalizedList, written)
            }
        }
        return (grabIds, intensityBpsList, loggedAtList, epochIds, finalizedList);
    }

    function batchReserveSlots(uint256 count) external returns (uint256 firstSlotIndex) {
        if (!_authorizedKeepers[msg.sender]) revert YugeAI_Unauthorized();
        if (count == 0 || count > YUGEAI_MAX_BATCH_SLOTS) revert YugeAI_BadInput();
        uint256 epochEnd = YugeAIHelpers.epochEndTime(genesisTime, _currentEpoch, YUGEAI_EPOCH_DURATION_SECS);
        if (block.timestamp >= epochEnd) _currentEpoch++;
        uint256 slotsUsed = _nextSlotIndex - YugeAIHelpers.epochStartSlot(_currentEpoch, YUGEAI_MAX_GRABS_PER_EPOCH);
        if (slotsUsed + count > YUGEAI_MAX_GRABS_PER_EPOCH) {
            _currentEpoch++;
            slotsUsed = 0;
        }
        firstSlotIndex = _nextSlotIndex;
        for (uint256 i = 0; i < count; i++) {
            _slots[_nextSlotIndex++] = BatchSlot({ bandBps: 0, sealedAt: 0, variantId: 0, sealed: false });
        }
        return firstSlotIndex;
    }

    function getDealsBatch(uint256 fromId, uint256 limit) external view returns (
        uint256[] memory dealIds,
        uint96[] memory amounts,
        uint64[] memory createdAtBlocks,
        address[] memory parties,
        bool[] memory actives,
        bool[] memory closeds
    ) {
        uint256 cap = limit > 51 ? 51 : limit;
        dealIds = new uint256[](cap);
        amounts = new uint96[](cap);
        createdAtBlocks = new uint64[](cap);
        parties = new address[](cap);
        actives = new bool[](cap);
        closeds = new bool[](cap);
        uint256 written = 0;
        for (uint256 id = fromId; id < _nextDealId && written < cap; id++) {
            DealSlot storage d = _deals[id];
            dealIds[written] = id;
            amounts[written] = d.amountWei;
            createdAtBlocks[written] = d.createdAtBlock;
            parties[written] = d.party;
            actives[written] = d.active;
            closeds[written] = d.closed;
            written++;
        }
        if (written < cap) {
            assembly {
                mstore(dealIds, written)
                mstore(amounts, written)
                mstore(createdAtBlocks, written)
                mstore(parties, written)
                mstore(actives, written)
                mstore(closeds, written)
            }
        }
        return (dealIds, amounts, createdAtBlocks, parties, actives, closeds);
    }

    function isWinningGrab(uint256 grabId) external view returns (bool) {
        GrabRecord storage r = _grabs[grabId];
        return r.loggedAt != 0 && YugeAIHelpers.isWinningIntensity(r.intensityBps, YUGEAI_WINNING_INTENSITY_THRESHOLD_BPS);
    }

    function epochGrabCount(uint256 epochId) external view returns (uint256) {
        return _epochGrabCount[epochId];
    }

    function protocolRevision() external pure returns (uint256) {
        return YUGEAI_PROTOCOL_REV;
    }

    function namespaceSalt() external pure returns (bytes32) {
        return YUGEAI_NAMESPACE_SALT;
    }

    function getSlotBatch(uint256 fromIndex, uint256 limit) external view returns (
        uint256[] memory slotIndices,
        uint88[] memory bandBpsList,
        uint40[] memory sealedAtList,
        uint64[] memory variantIds,
        bool[] memory sealedList
    ) {
        uint256 cap = limit > 61 ? 61 : limit;
        slotIndices = new uint256[](cap);
        bandBpsList = new uint88[](cap);
        sealedAtList = new uint40[](cap);
        variantIds = new uint64[](cap);
        sealedList = new bool[](cap);
        uint256 written = 0;
        for (uint256 idx = fromIndex; idx < _nextSlotIndex && written < cap; idx++) {
            BatchSlot storage s = _slots[idx];
            slotIndices[written] = idx;
            bandBpsList[written] = s.bandBps;
            sealedAtList[written] = s.sealedAt;
            variantIds[written] = s.variantId;
            sealedList[written] = s.sealed;
            written++;
        }
        if (written < cap) {
            assembly {
                mstore(slotIndices, written)
                mstore(bandBpsList, written)
                mstore(sealedAtList, written)
                mstore(variantIds, written)
                mstore(sealedList, written)
            }
        }
        return (slotIndices, bandBpsList, sealedAtList, variantIds, sealedList);
    }

    function getGrabFull(uint256 grabId) external view returns (GrabRecord memory) {
        return _grabs[grabId];
    }

    function getDealFull(uint256 dealId) external view returns (DealSlot memory) {
        return _deals[dealId];
    }

    function getSlotFull(uint256 slotIndex) external view returns (BatchSlot memory) {
        return _slots[slotIndex];
    }

    function remainingSweepCap() external view returns (uint256) {
        return sweepCapWei > _totalSweptWei ? sweepCapWei - _totalSweptWei : 0;
    }

    function nextEpochEndTime() external view returns (uint256) {
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        return YugeAIHelpers.epochEndTime(genesisTime, epoch, YUGEAI_EPOCH_DURATION_SECS);
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function grabTier(uint256 grabId) external view returns (uint8) {
        GrabRecord storage r = _grabs[grabId];
        return r.loggedAt == 0 ? 0 : YugeAIHelpers.tierFromIntensity(r.intensityBps);
    }

    function commanderAddress() external view returns (address) { return commander; }
    function treasuryAddress() external view returns (address) { return treasury; }
    function oracleAddress() external view returns (address) { return covfefeOracle; }
    function dealMakerAddress() external view returns (address) { return dealMaker; }
    function vaultAddress() external view returns (address) { return vault; }
    function genesisTimestamp() external view returns (uint256) { return genesisTime; }
    function deployBlockNumber() external view returns (uint256) { return deployBlock; }
    function isPaused() external view returns (bool) { return guardPaused; }
    function maxGrabsPerEpoch() external pure returns (uint256) { return YUGEAI_MAX_GRABS_PER_EPOCH; }
    function epochDurationSeconds() external pure returns (uint256) { return YUGEAI_EPOCH_DURATION_SECS; }
    function minGrabBps() external pure returns (uint256) { return YUGEAI_MIN_GRAB_BPS; }
    function maxGrabBps() external pure returns (uint256) { return YUGEAI_MAX_GRAB_BPS; }
    function oracleCooldownBlocks() external pure returns (uint256) { return YUGEAI_ORACLE_COOLDOWN_BLOCKS; }
    function maxDealSlots() external pure returns (uint256) { return YUGEAI_MAX_DEAL_SLOTS; }
    function winningIntensityThresholdBps() external pure returns (uint256) { return YUGEAI_WINNING_INTENSITY_THRESHOLD_BPS; }
    function goldenEpochRewardBps() external pure returns (uint256) { return YUGEAI_GOLDEN_EPOCH_REWARD_BPS; }
    function vaultFeeBps() external pure returns (uint256) { return YUGEAI_VAULT_FEE_BPS; }
    function maxBatchGrabs() external pure returns (uint256) { return YUGEAI_MAX_BATCH_GRABS; }
    function maxBatchSlots() external pure returns (uint256) { return YUGEAI_MAX_BATCH_SLOTS; }
    function bpsDenominator() external pure returns (uint256) { return YUGEAI_BPS; }

    function statsView() external view returns (
        uint256 totalGrabs,
        uint256 totalDeals,
        uint256 totalSlots,
        uint256 totalSwept,
        uint256 vaultBal,
        uint256 currentEpoch,
        bool paused
    ) {
        return (
            _nextGrabId,
            _nextDealId,
            _nextSlotIndex,
            _totalSweptWei,
            _vaultBalanceWei,
            (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS,
            guardPaused
        );
    }

    function hasClaimReward(uint256 claimIndex) external view returns (bool) {
        return _claimRewardWei[claimIndex] > 0;
    }

    function claimRewardAmount(uint256 claimIndex) external view returns (uint256) {
        return _claimRewardWei[claimIndex];
    }

    function countWinningGrabsInEpoch(uint256 epochId) external view returns (uint256 count) {
        uint256 startSlot = epochId * YUGEAI_MAX_GRABS_PER_EPOCH;
        uint256 endSlot = startSlot + YUGEAI_MAX_GRABS_PER_EPOCH;
        for (uint256 id = startSlot; id < endSlot && id < _nextGrabId; id++) {
            if (YugeAIHelpers.isWinningIntensity(_grabs[id].intensityBps, YUGEAI_WINNING_INTENSITY_THRESHOLD_BPS)) count++;
        }
        return count;
    }

    function sumIntensityInEpoch(uint256 epochId) external view returns (uint256 sum) {
        uint256 startSlot = epochId * YUGEAI_MAX_GRABS_PER_EPOCH;
        uint256 endSlot = startSlot + YUGEAI_MAX_GRABS_PER_EPOCH;
        for (uint256 id = startSlot; id < endSlot && id < _nextGrabId; id++) {
            sum += _grabs[id].intensityBps;
        }
        return sum;
    }

    function activeDealsCount() external view returns (uint256 count) {
        for (uint256 id = 0; id < _nextDealId; id++) {
            if (_deals[id].active && !_deals[id].closed) count++;
        }
        return count;
    }

    function sealedSlotsCount() external view returns (uint256 count) {
        for (uint256 idx = 0; idx < _nextSlotIndex; idx++) {
            if (_slots[idx].sealed) count++;
        }
        return count;
    }

    function getCommander() external view returns (address) { return commander; }
    function getTreasury() external view returns (address) { return treasury; }
    function getCovfefeOracle() external view returns (address) { return covfefeOracle; }
    function getDealMaker() external view returns (address) { return dealMaker; }
    function getVault() external view returns (address) { return vault; }
    function getGenesisTime() external view returns (uint256) { return genesisTime; }
    function getSweepCapWei() external view returns (uint256) { return sweepCapWei; }
    function getDeployBlock() external view returns (uint256) { return deployBlock; }
    function getNextGrabId() external view returns (uint256) { return _nextGrabId; }
    function getNextDealId() external view returns (uint256) { return _nextDealId; }
    function getNextSlotIndex() external view returns (uint256) { return _nextSlotIndex; }
    function getTotalSweptWei() external view returns (uint256) { return _totalSweptWei; }
    function getVaultBalanceWei() external view returns (uint256) { return _vaultBalanceWei; }
    function getLastOracleBlock() external view returns (uint256) { return _lastOracleBlock; }
    function getCurrentEpochInternal() external view returns (uint256) { return _currentEpoch; }

    function intensityBpsForGrab(uint256 grabId) external view returns (uint88) {
        return _grabs[grabId].intensityBps;
    }

    function loggedAtForGrab(uint256 grabId) external view returns (uint40) {
        return _grabs[grabId].loggedAt;
    }

    function epochIdForGrab(uint256 grabId) external view returns (uint64) {
        return _grabs[grabId].epochId;
    }

    function finalizedForGrab(uint256 grabId) external view returns (bool) {
        return _grabs[grabId].finalized;
    }

    function amountWeiForDeal(uint256 dealId) external view returns (uint96) {
        return _deals[dealId].amountWei;
    }

    function partyForDeal(uint256 dealId) external view returns (address) {
        return _deals[dealId].party;
    }

    function activeForDeal(uint256 dealId) external view returns (bool) {
        return _deals[dealId].active;
    }

    function closedForDeal(uint256 dealId) external view returns (bool) {
        return _deals[dealId].closed;
    }

    function bandBpsForSlot(uint256 slotIndex) external view returns (uint88) {
        return _slots[slotIndex].bandBps;
    }

    function sealedAtForSlot(uint256 slotIndex) external view returns (uint40) {
        return _slots[slotIndex].sealedAt;
    }

    function variantIdForSlot(uint256 slotIndex) external view returns (uint64) {
        return _slots[slotIndex].variantId;
    }

    function sealedForSlot(uint256 slotIndex) external view returns (bool) {
        return _slots[slotIndex].sealed;
    }

    function epochSnapshotRecorded(uint256 epochId) external view returns (bool) {
        return _epochSnapshots[epochId].recorded;
    }

    function epochSnapshotTotalGrabs(uint256 epochId) external view returns (uint32) {
        return _epochSnapshots[epochId].totalGrabs;
    }

    function epochSnapshotSumIntensityBps(uint256 epochId) external view returns (uint128) {
        return _epochSnapshots[epochId].sumIntensityBps;
    }

    function epochSnapshotRecordedAtBlock(uint256 epochId) external view returns (uint64) {
        return _epochSnapshots[epochId].recordedAtBlock;
    }

    function timeUntilNextEpochEnd() external view returns (uint256) {
        uint256 end = YugeAIHelpers.epochEndTime(genesisTime, (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS, YUGEAI_EPOCH_DURATION_SECS);
        return block.timestamp >= end ? 0 : end - block.timestamp;
    }

    function currentEpochStartTime() external view returns (uint256) {
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        return genesisTime + epoch * YUGEAI_EPOCH_DURATION_SECS;
    }

    function currentEpochEndTime() external view returns (uint256) {
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        return YugeAIHelpers.epochEndTime(genesisTime, epoch, YUGEAI_EPOCH_DURATION_SECS);
    }

    function grabsInCurrentEpoch() external view returns (uint256) {
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        uint256 startSlot = epoch * YUGEAI_MAX_GRABS_PER_EPOCH;
        uint256 count = 0;
        for (uint256 id = startSlot; id < _nextGrabId && id < startSlot + YUGEAI_MAX_GRABS_PER_EPOCH; id++) {
            if (_grabs[id].loggedAt != 0) count++;
        }
        return count;
    }

    function slotsRemainingInCurrentEpoch() external view returns (uint256) {
        uint256 epoch = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        uint256 startSlot = epoch * YUGEAI_MAX_GRABS_PER_EPOCH;
        uint256 used = _nextSlotIndex > startSlot ? _nextSlotIndex - startSlot : 0;
        if (used > YUGEAI_MAX_GRABS_PER_EPOCH) return 0;
        return YUGEAI_MAX_GRABS_PER_EPOCH - used;
    }

    function canOracleUpdate() external view returns (bool) {
        return block.number >= _lastOracleBlock + YUGEAI_ORACLE_COOLDOWN_BLOCKS;
    }

    function blocksUntilOracleCanUpdate() external view returns (uint256) {
        if (block.number >= _lastOracleBlock + YUGEAI_ORACLE_COOLDOWN_BLOCKS) return 0;
        return (_lastOracleBlock + YUGEAI_ORACLE_COOLDOWN_BLOCKS) - block.number;
    }

    function maxGoldenRewardFromVault() external view returns (uint256) {
        return YugeAIHelpers.bpsToWei(_vaultBalanceWei, YUGEAI_GOLDEN_EPOCH_REWARD_BPS);
    }

    function sweepCapRemaining() external view returns (uint256) {
        return sweepCapWei > _totalSweptWei ? sweepCapWei - _totalSweptWei : 0;
    }

    uint256 private constant YUGEAI_CLAIM_SCAN_CAP = 1000;

    function totalClaimRewardsSet() external view returns (uint256 count) {
        for (uint256 i = 0; i < YUGEAI_CLAIM_SCAN_CAP; i++) {
            if (_claimRewardWei[i] > 0) count++;
        }
        return count;
    }

    function getGrabsInEpochRange(uint256 epochFrom, uint256 epochTo, uint256 maxResults) external view returns (
        uint256[] memory grabIds,
        uint88[] memory intensities,
        uint64[] memory epochIds
    ) {
        uint256 cap = YugeAIHelpers.minUint256(maxResults, 81);
        grabIds = new uint256[](cap);
        intensities = new uint88[](cap);
        epochIds = new uint64[](cap);
        uint256 written = 0;
        for (uint256 e = epochFrom; e <= epochTo && written < cap; e++) {
            uint256 startSlot = e * YUGEAI_MAX_GRABS_PER_EPOCH;
            uint256 endSlot = startSlot + YUGEAI_MAX_GRABS_PER_EPOCH;
            for (uint256 id = startSlot; id < endSlot && id < _nextGrabId && written < cap; id++) {
                GrabRecord storage r = _grabs[id];
                if (r.loggedAt != 0) {
                    grabIds[written] = id;
                    intensities[written] = r.intensityBps;
                    epochIds[written] = r.epochId;
                    written++;
                }
            }
        }
        if (written < cap) {
            assembly {
                mstore(grabIds, written)
                mstore(intensities, written)
                mstore(epochIds, written)
            }
        }
        return (grabIds, intensities, epochIds);
    }

    function getActiveDealIds(uint256 maxCount) external view returns (uint256[] memory dealIds) {
        uint256 cap = YugeAIHelpers.minUint256(maxCount, 31);
        dealIds = new uint256[](cap);
        uint256 written = 0;
        for (uint256 id = 0; id < _nextDealId && written < cap; id++) {
            if (_deals[id].active && !_deals[id].closed) {
                dealIds[written++] = id;
            }
        }
        if (written < cap) {
            assembly { mstore(dealIds, written) }
        }
        return dealIds;
    }

    function getSealedSlotIndices(uint256 maxCount) external view returns (uint256[] memory indices) {
        uint256 cap = YugeAIHelpers.minUint256(maxCount, 41);
        indices = new uint256[](cap);
        uint256 written = 0;
        for (uint256 idx = 0; idx < _nextSlotIndex && written < cap; idx++) {
            if (_slots[idx].sealed) {
                indices[written++] = idx;
            }
        }
        if (written < cap) {
            assembly { mstore(indices, written) }
        }
        return indices;
    }

    // --- Role and config views (alias for external integrations) ---
    function getConfig() external view returns (
        address cmd,
        address tr,
        address oracle,
        address dm,
        address v,
        uint256 genesis,
        uint256 cap,
        uint256 blockDeploy
    ) {
        return (commander, treasury, covfefeOracle, dealMaker, vault, genesisTime, sweepCapWei, deployBlock);
    }

    function getCounts() external view returns (
        uint256 grabs,
        uint256 deals,
        uint256 slots,
        uint256 swept,
        uint256 vaultBal
    ) {
        return (_nextGrabId, _nextDealId, _nextSlotIndex, _totalSweptWei, _vaultBalanceWei);
    }

    function getEpochInfo() external view returns (
        uint256 currentEpochId,
        uint256 epochStartTs,
        uint256 epochEndTs,
        uint256 secsRemaining
    ) {
        uint256 e = (block.timestamp - genesisTime) / YUGEAI_EPOCH_DURATION_SECS;
        uint256 start = genesisTime + e * YUGEAI_EPOCH_DURATION_SECS;
        uint256 end = start + YUGEAI_EPOCH_DURATION_SECS;
        uint256 rem = block.timestamp >= end ? 0 : end - block.timestamp;
        return (e, start, end, rem);
    }

    function checkKeeper(address account) external view returns (bool) {
        return _authorizedKeepers[account];
    }

    function getCovfefeValue(bytes32 key) external view returns (bytes32) {
        return _covfefeStore[key];
    }

    function getCovfefeUpdatedBlock(bytes32 key) external view returns (uint64) {
        return _covfefeUpdatedBlock[key];
    }

    function grabExists(uint256 grabId) external view returns (bool) {
        return grabId < _nextGrabId && _grabs[grabId].loggedAt != 0;
    }

    function dealExists(uint256 dealId) external view returns (bool) {
        return dealId < _nextDealId;
    }

    function slotExists(uint256 slotIndex) external view returns (bool) {
        return slotIndex < _nextSlotIndex;
    }

    function averageIntensityForEpoch(uint256 epochId) external view returns (uint256 avgBps) {
        EpochSnapshot storage s = _epochSnapshots[epochId];
        if (!s.recorded || s.totalGrabs == 0) return 0;
        return uint256(s.sumIntensityBps) / uint256(s.totalGrabs);
    }

    function winningGrabsInEpoch(uint256 epochId) external view returns (uint256) {
        return this.countWinningGrabsInEpoch(epochId);
    }

    function totalIntensityInEpoch(uint256 epochId) external view returns (uint256) {
        return this.sumIntensityInEpoch(epochId);
    }

    function tierForGrab(uint256 grabId) external view returns (uint8) {
        return this.grabTier(grabId);
    }

    function remainingSweepCapacity() external view returns (uint256) {
        return this.remainingSweepCap();
    }

    function maxGoldenReward() external view returns (uint256) {
