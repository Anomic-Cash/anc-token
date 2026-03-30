// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IMiningVerifier
 * @author Anomic Protocol
 * @notice Interface for ZK proof verification of mining reward claims (e.g. mining_claim circuit).
 */
interface IMiningVerifier {
    /// @notice Verifies a mining claim ZK proof
    /// @param commitment Deposit commitment hash
    /// @param recipient Reward recipient
    /// @param proof ZK proof bytes (e.g. Groth16)
    /// @return True if proof is valid
    function verifyProof(bytes32 commitment, address recipient, bytes calldata proof) external view returns (bool);
}

/**
 * @title AnomicCash (ANC)
 * @author Anomic Protocol
 * @notice Privacy-focused governance token for the Anomic Protocol
 * @dev Token-only contract. Staking and relayer lock live in GovernanceLock.
 *
 * Distribution (12M fixed supply):
 * - 55% DAO Treasury (6,600,000 ANC) - 5 year linear vest, 3 month cliff
 * - 30% Team & Supporters (3,600,000 ANC) - 1.2M at TGE, 2.4M linear over 3 years
 * - 10% Anonymity Mining (1,200,000 ANC) - 1 year linear distribution
 * - 5% Airdrop (600,000 ANC) - Early users, claimable within 1 year
 */
contract AnomicCash is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors (gas-efficient) ============
    error ZeroAddress();
    error ZeroGovernance();
    error ZeroMining();
    error ZeroTeam();
    error NotAuthorized();
    error ZeroMiningRewards();
    error MixerNotSet();
    error AlreadyClaimed();
    error ZeroRecipient();
    error MiningPoolExhausted();
    error InvalidProof();
    error OnlyMixerWhenNoVerifier();
    error CliffNotReached();
    error NothingToVest();
    error ZeroMixer();
    error NotGovernance();

    // ============ Constants ============
    /// @notice Maximum token supply (12M ANC)
    uint256 public constant MAX_SUPPLY = 12_000_000 * 10**18; // 12M ANC
    /// @notice Airdrop allocation (5%)
    uint256 public constant AIRDROP_ALLOCATION = 600_000 * 10**18;      // 5%
    /// @notice DAO treasury allocation (55%)
    uint256 public constant DAO_ALLOCATION = 6_600_000 * 10**18;        // 55%
    /// @notice Team immediate allocation at TGE (1.2M)
    uint256 public constant TEAM_IMMEDIATE = 1_200_000 * 10**18;        // 1.2M at TGE
    /// @notice Team vesting allocation (2.4M)
    uint256 public constant TEAM_VESTING_ALLOCATION = 2_400_000 * 10**18; // 2.4M vesting
    /// @notice Total team allocation (30%)
    uint256 public constant TEAM_ALLOCATION = TEAM_IMMEDIATE + TEAM_VESTING_ALLOCATION; // 30%
    /// @notice Anonymity mining allocation (10%)
    uint256 public constant MINING_ALLOCATION = 1_200_000 * 10**18;     // 10%
    /// @notice DAO vesting duration (5 years)
    uint256 public constant DAO_VESTING_DURATION = 5 * 365 days;
    /// @notice DAO vesting cliff (90 days)
    uint256 public constant DAO_CLIFF = 90 days;
    /// @notice Team vesting duration (3 years)
    uint256 public constant TEAM_VESTING_DURATION = 3 * 365 days;
    /// @notice Mining distribution duration (1 year)
    uint256 public constant MINING_DURATION = 365 days;
    /// @notice Airdrop claim period (1 year)
    uint256 public constant AIRDROP_CLAIM_PERIOD = 365 days;

    // ============ State Variables ============
    /// @notice Mixer contract address (for mining claim when no verifier)
    address public mixer;
    /// @notice Governance contract address
    address public governance;
    /// @notice Mining rewards pool address
    address public miningRewards;
    /// @notice Team vesting beneficiary
    address public teamBeneficiary;
    /// @notice AnomicTrees contract for mining roots
    address public miningTrees;
    /// @notice ZK verifier for mining claims (0 = only mixer can claim)
    address public miningVerifier;
    /// @notice Vesting start timestamp (immutable)
    // solhint-disable-next-line immutable-vars-naming, use-natspec
    uint256 public immutable vestingStartTime;
    /// @notice DAO vested amount so far
    uint256 public daoVested;
    /// @notice Team vested amount so far
    uint256 public teamVested;
    /// @notice Commitment => whether mining reward was claimed
    mapping(bytes32 => bool) public claimedRewards;
    /// @notice Current mining reward per claim (in wei)
    uint256 public miningRewardRate = 10 * 10**18;
    /// @notice Total mining rewards distributed
    uint256 public totalMiningDistributed;

    // ============ Events ============
    /// @notice Emitted when a mining reward is claimed
    /// @param commitment Deposit commitment
    /// @param recipient Reward recipient
    /// @param amount ANC amount claimed
    event MiningRewardClaimed(bytes32 indexed commitment, address indexed recipient, uint256 indexed amount);
    /// @notice Emitted when mining reward rate is updated
    /// @param oldRate Previous rate
    /// @param newRate New rate
    event MiningRewardRateUpdated(uint256 indexed oldRate, uint256 indexed newRate);
    /// @notice Emitted when DAO tokens are vested
    /// @param amount Amount vested in this call
    /// @param totalVested Total DAO vested so far
    event DAOVested(uint256 indexed amount, uint256 indexed totalVested);
    /// @notice Emitted when team tokens are vested
    /// @param amount Amount vested in this call
    /// @param totalVested Total team vested so far
    event TeamVested(uint256 indexed amount, uint256 indexed totalVested);
    /// @notice Emitted when airdrop is claimed
    /// @param user Claimant
    /// @param amount Amount claimed
    event AirdropClaimed(address indexed user, uint256 indexed amount);

    // ============ Constructor ============
    /// @notice Deploys ANC and mints initial allocations to governance, mining pool, and team
    /// @param _governance Governance / airdrop recipient
    /// @param _miningRewards Mining rewards pool address
    /// @param _teamVesting Team immediate + vesting beneficiary
    constructor(
        address _governance,
        address _miningRewards,
        address _teamVesting
    ) ERC20("Anomic Cash", "ANC") ERC20Permit("Anomic Cash") Ownable(msg.sender) {
        if (_governance == address(0)) revert ZeroGovernance();
        if (_miningRewards == address(0)) revert ZeroMining();
        if (_teamVesting == address(0)) revert ZeroTeam();

        governance = _governance;
        miningRewards = _miningRewards;
        teamBeneficiary = _teamVesting;
        vestingStartTime = block.timestamp;

        _mint(_miningRewards, MINING_ALLOCATION);
        _mint(_governance, AIRDROP_ALLOCATION);
        _mint(_teamVesting, TEAM_IMMEDIATE);
    }

    // ============ Anonymity Mining ============

    /// @notice Set AnomicTrees contract address (for mining roots)
    /// @param _trees AnomicTrees address
    function setMiningTrees(address _trees) external {
        if (msg.sender != governance && msg.sender != owner()) revert NotAuthorized();
        if (_trees == address(0)) revert ZeroAddress();
        miningTrees = _trees;
    }

    /// @notice Set ZK verifier for mining claims; 0 = only mixer can call claimMiningReward
    /// @param _verifier Verifier contract address
    function setMiningVerifier(address _verifier) external {
        if (msg.sender != governance && msg.sender != owner()) revert NotAuthorized();
        miningVerifier = _verifier;
    }

    /// @notice Set mining rewards pool address (governance/owner)
    /// @param _miningRewards New pool address
    function setMiningRewards(address _miningRewards) external {
        if (msg.sender != governance && msg.sender != owner()) revert NotAuthorized();
        if (_miningRewards == address(0)) revert ZeroMiningRewards();
        miningRewards = _miningRewards;
    }

    /// @notice Claim ANC mining reward for a spent note (proof verified on-chain or via mixer)
    /// @param commitment Deposit commitment
    /// @param recipient Reward recipient
    /// @param proof ZK proof (required if miningVerifier set)
    function claimMiningReward(
        bytes32 commitment,
        address recipient,
        bytes calldata proof
    ) external nonReentrant {
        if (mixer == address(0)) revert MixerNotSet();
        if (claimedRewards[commitment]) revert AlreadyClaimed();
        if (recipient == address(0)) revert ZeroRecipient();
        if (totalMiningDistributed + miningRewardRate > MINING_ALLOCATION) revert MiningPoolExhausted();

        if (miningVerifier != address(0)) {
            if (!IMiningVerifier(miningVerifier).verifyProof(commitment, recipient, proof)) revert InvalidProof();
        } else {
            if (msg.sender != mixer) revert OnlyMixerWhenNoVerifier();
        }

        claimedRewards[commitment] = true;
        totalMiningDistributed += miningRewardRate;

        IERC20(address(this)).safeTransferFrom(miningRewards, recipient, miningRewardRate);

        emit MiningRewardClaimed(commitment, recipient, miningRewardRate);
    }

    /// @notice Check if a commitment has already claimed its mining reward
    /// @param commitment Deposit commitment
    /// @return True if already claimed
    function hasClaimedReward(bytes32 commitment) external view returns (bool) {
        return claimedRewards[commitment];
    }

    /// @notice Remaining ANC in the mining pool
    /// @return Amount left to distribute
    function remainingMiningRewards() external view returns (uint256) {
        return MINING_ALLOCATION - totalMiningDistributed;
    }

    // ============ Vesting ============

    /// @notice Vest DAO allocation (linear over 5 years, 90-day cliff)
    function vestDAO() external {
        if (block.timestamp < vestingStartTime + DAO_CLIFF) revert CliffNotReached();

        uint256 elapsed = block.timestamp - vestingStartTime;
        uint256 vestable = (DAO_ALLOCATION * elapsed) / DAO_VESTING_DURATION;

        if (vestable > DAO_ALLOCATION) vestable = DAO_ALLOCATION;

        uint256 toVest = vestable - daoVested;
        if (toVest == 0) revert NothingToVest();

        daoVested += toVest;
        _mint(governance, toVest);

        emit DAOVested(toVest, daoVested);
    }

    /// @notice Vest team allocation (linear over 3 years, no cliff)
    function vestTeam() external {
        uint256 elapsed = block.timestamp - vestingStartTime;
        uint256 vestable = (TEAM_VESTING_ALLOCATION * elapsed) / TEAM_VESTING_DURATION;

        if (vestable > TEAM_VESTING_ALLOCATION) vestable = TEAM_VESTING_ALLOCATION;

        uint256 toVest = vestable - teamVested;
        if (toVest == 0) revert NothingToVest();

        teamVested += toVest;
        _mint(teamBeneficiary, toVest);

        emit TeamVested(toVest, teamVested);
    }

    /// @notice Current vestable DAO amount (view)
    /// @return Amount that can be vested now
    function getVestableDAO() external view returns (uint256) {
        if (block.timestamp < vestingStartTime + DAO_CLIFF) return 0;

        uint256 elapsed = block.timestamp - vestingStartTime;
        uint256 vestable = (DAO_ALLOCATION * elapsed) / DAO_VESTING_DURATION;

        if (vestable > DAO_ALLOCATION) vestable = DAO_ALLOCATION;

        return vestable - daoVested;
    }

    /// @notice Current vestable team amount (view)
    /// @return Amount that can be vested now
    function getVestableTeam() external view returns (uint256) {
        uint256 elapsed = block.timestamp - vestingStartTime;
        uint256 vestable = (TEAM_VESTING_ALLOCATION * elapsed) / TEAM_VESTING_DURATION;

        if (vestable > TEAM_VESTING_ALLOCATION) vestable = TEAM_VESTING_ALLOCATION;

        return vestable - teamVested;
    }

    // ============ Owner ============

    /// @notice Set mixer contract (owner only)
    /// @param _mixer Mixer address
    function setMixer(address _mixer) external onlyOwner {
        if (_mixer == address(0)) revert ZeroMixer();
        mixer = _mixer;
    }

    /// @notice Set governance address (governance or owner)
    /// @param _governance New governance address
    function setGovernance(address _governance) external {
        if (msg.sender != governance && msg.sender != owner()) revert NotAuthorized();
        if (_governance == address(0)) revert ZeroGovernance();
        governance = _governance;
    }

    /// @notice Set mining reward per claim (governance only)
    /// @param _rate New rate in wei
    function setMiningRewardRate(uint256 _rate) external {
        if (msg.sender != governance) revert NotGovernance();
        emit MiningRewardRateUpdated(miningRewardRate, _rate);
        miningRewardRate = _rate;
    }

    // ============ Overrides ============

    /// @notice ERC20Permit nonce for an owner
    /// @param owner Account
    /// @return Current nonce
    function nonces(address owner)
        public
        view
        override(ERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    // ============ View ============

    /// @notice Mining pool stats
    /// @return _totalMiningDistributed Total distributed
    /// @return _remainingMining Remaining in pool
    /// @return _currentRewardRate Current reward per claim
    function getMiningStats() external view returns (
        uint256 _totalMiningDistributed,
        uint256 _remainingMining,
        uint256 _currentRewardRate
    ) {
        _totalMiningDistributed = totalMiningDistributed;
        _remainingMining = MINING_ALLOCATION - totalMiningDistributed;
        _currentRewardRate = miningRewardRate;
    }
}
