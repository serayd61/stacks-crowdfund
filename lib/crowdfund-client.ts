/**
 * Stacks Crowdfund Client
 *
 * TypeScript SDK integration for interacting with the crowdfund and
 * milestone-crowdfund smart contracts on Stacks. Uses @stacks/connect
 * for wallet authentication and contract calls, @stacks/transactions
 * for building transactions and reading on-chain state, and
 * @stacks/network for network configuration.
 *
 * Contracts:
 *   - crowdfund.clar: basic campaign lifecycle (create, contribute, claim, refund)
 *   - milestone-crowdfund.clar: milestone-based fund release with backer voting
 */

// ---------- @stacks/connect imports ----------
import {
  showConnect,
  showContractCall,
  AppConfig,
  UserSession,
} from '@stacks/connect';

// ---------- @stacks/transactions imports ----------
import {
  makeContractCall,
  callReadOnlyFunction,
  broadcastTransaction,
  uintCV,
  principalCV,
  stringAsciiCV,
  stringUtf8CV,
  bufferCV,
  trueCV,
  falseCV,
  noneCV,
  someCV,
  tupleCV,
  listCV,
  cvToJSON,
  cvToString,
  AnchorMode,
  PostConditionMode,
  makeStandardSTXPostCondition,
  FungibleConditionCode,
  contractPrincipalCV,
  standardPrincipalCV,
  ClarityValue,
} from '@stacks/transactions';

// ---------- @stacks/network imports ----------
import { StacksMainnet } from '@stacks/network';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Deployed contract address on mainnet (from README) */
const CONTRACT_ADDRESS = 'SP2PEBKJ2W1ZDDF2QQ6Y4FXKZEDPT9J9R2NKD9WJB';

/** Contract identifiers */
const CROWDFUND_CONTRACT = 'crowdfund';
const MILESTONE_CONTRACT = 'milestone-crowdfund';

/** 1 STX = 1_000_000 micro-STX */
const MICRO_STX = 1_000_000;

/** Platform fee: 2 % (200 basis points) -- mirrors the on-chain constant */
const PLATFORM_FEE_BPS = 200;

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

const network = new StacksMainnet();

// ---------------------------------------------------------------------------
// Session helpers
// ---------------------------------------------------------------------------

const appConfig = new AppConfig(['store_write', 'publish_data']);
const userSession = new UserSession({ appConfig });

/**
 * Returns the Stacks address of the currently authenticated user, or null if
 * no session is active.
 */
export function getCurrentAddress(): string | null {
  if (!userSession.isUserSignedIn()) return null;
  const userData = userSession.loadUserData();
  return userData.profile.stxAddress?.mainnet ?? null;
}

// ---------------------------------------------------------------------------
// Wallet connection
// ---------------------------------------------------------------------------

export interface ConnectOptions {
  /** Name shown in the wallet popup */
  appName?: string;
  /** URL of the application icon */
  appIconUrl?: string;
  /** Callback fired after successful authentication */
  onFinish?: () => void;
  /** Callback fired when the user cancels */
  onCancel?: () => void;
}

/**
 * Launch the Stacks wallet authentication flow using `showConnect` from
 * @stacks/connect. The user will be presented with a wallet popup to
 * authorise the application.
 */
export function connectWallet(opts: ConnectOptions = {}): void {
  showConnect({
    appDetails: {
      name: opts.appName ?? 'Stacks Crowdfund',
      icon: opts.appIconUrl ?? '/logo.png',
    },
    onFinish: () => {
      opts.onFinish?.();
    },
    onCancel: () => {
      opts.onCancel?.();
    },
    userSession,
  });
}

/**
 * Disconnect the current wallet session.
 */
export function disconnectWallet(): void {
  if (userSession.isUserSignedIn()) {
    userSession.signUserOut();
  }
}

/**
 * Check whether a user is currently signed in.
 */
export function isWalletConnected(): boolean {
  return userSession.isUserSignedIn();
}

// ---------------------------------------------------------------------------
// Generic helpers
// ---------------------------------------------------------------------------

/**
 * Convert STX (human-readable) to micro-STX (on-chain uint).
 */
export function stxToMicroStx(stx: number): number {
  return Math.floor(stx * MICRO_STX);
}

/**
 * Convert micro-STX (on-chain uint) to STX (human-readable).
 */
export function microStxToStx(microStx: number): number {
  return microStx / MICRO_STX;
}

/**
 * Internal helper: read a read-only function from the crowdfund contract.
 */
async function readCrowdfund(
  functionName: string,
  args: ClarityValue[],
  contractName: string = CROWDFUND_CONTRACT,
): Promise<ClarityValue> {
  const senderAddress = getCurrentAddress() ?? CONTRACT_ADDRESS;

  const result = await callReadOnlyFunction({
    contractAddress: CONTRACT_ADDRESS,
    contractName,
    functionName,
    functionArgs: args,
    network,
    senderAddress,
  });

  return result;
}

// ===========================================================================
// crowdfund.clar -- Campaign lifecycle
// ===========================================================================

// ---------------------------------------------------------------------------
// createCampaign
// ---------------------------------------------------------------------------

export interface CreateCampaignParams {
  /** Campaign title (up to 128 UTF-8 characters) */
  title: string;
  /** Campaign description (up to 512 UTF-8 characters) */
  description: string;
  /** Fundraising goal in micro-STX */
  goal: number;
  /** Duration in Stacks blocks (~10 min each). e.g. 4320 blocks ~ 30 days */
  duration: number;
  /** Callback after the transaction is submitted */
  onFinish?: (data: any) => void;
  /** Callback if the user cancels the transaction */
  onCancel?: () => void;
}

/**
 * Create a new crowdfunding campaign via `showContractCall`.
 *
 * Maps to:
 * ```clarity
 * (create-campaign (title (string-utf8 128))
 *                  (description (string-utf8 512))
 *                  (goal uint)
 *                  (duration uint))
 * ```
 */
export function createCampaign(params: CreateCampaignParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'create-campaign',
    functionArgs: [
      stringUtf8CV(params.title),
      stringUtf8CV(params.description),
      uintCV(params.goal),
      uintCV(params.duration),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// contribute
// ---------------------------------------------------------------------------

export interface ContributeParams {
  /** Campaign ID (uint) */
  campaignId: number;
  /** Contribution amount in micro-STX */
  amount: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Contribute STX to an active campaign.
 *
 * A standard STX post-condition is attached so the wallet displays the
 * exact amount that will leave the user's account.
 *
 * Maps to:
 * ```clarity
 * (contribute (campaign-id uint) (amount uint))
 * ```
 */
export function contribute(params: ContributeParams): void {
  const senderAddress = getCurrentAddress();
  if (!senderAddress) {
    throw new Error('Wallet not connected. Call connectWallet() first.');
  }

  const postConditions = [
    makeStandardSTXPostCondition(
      senderAddress,
      FungibleConditionCode.Equal,
      params.amount,
    ),
  ];

  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'contribute',
    functionArgs: [
      uintCV(params.campaignId),
      uintCV(params.amount),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions,
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// claimFunds
// ---------------------------------------------------------------------------

export interface ClaimFundsParams {
  campaignId: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Claim raised funds after a successful campaign (creator only).
 *
 * Maps to:
 * ```clarity
 * (claim-funds (campaign-id uint))
 * ```
 */
export function claimFunds(params: ClaimFundsParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'claim-funds',
    functionArgs: [uintCV(params.campaignId)],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// enableRefunds
// ---------------------------------------------------------------------------

export interface EnableRefundsParams {
  campaignId: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Enable refunds for a failed campaign (creator only).
 *
 * Maps to:
 * ```clarity
 * (enable-refunds (campaign-id uint))
 * ```
 */
export function enableRefunds(params: EnableRefundsParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'enable-refunds',
    functionArgs: [uintCV(params.campaignId)],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// claimRefund
// ---------------------------------------------------------------------------

export interface ClaimRefundParams {
  campaignId: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Claim a refund for a failed campaign (contributor only).
 *
 * Maps to:
 * ```clarity
 * (claim-refund (campaign-id uint))
 * ```
 */
export function claimRefund(params: ClaimRefundParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'claim-refund',
    functionArgs: [uintCV(params.campaignId)],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// extendDeadline
// ---------------------------------------------------------------------------

export interface ExtendDeadlineParams {
  campaignId: number;
  /** Additional blocks to extend (e.g. 1440 ~ 10 days) */
  additionalBlocks: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Extend the deadline of an active campaign (creator only).
 *
 * Maps to:
 * ```clarity
 * (extend-deadline (campaign-id uint) (additional-blocks uint))
 * ```
 */
export function extendDeadline(params: ExtendDeadlineParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'extend-deadline',
    functionArgs: [
      uintCV(params.campaignId),
      uintCV(params.additionalBlocks),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// updateDescription
// ---------------------------------------------------------------------------

export interface UpdateDescriptionParams {
  campaignId: number;
  newDescription: string;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Update a campaign's description (creator only).
 *
 * Maps to:
 * ```clarity
 * (update-description (campaign-id uint) (new-description (string-utf8 512)))
 * ```
 */
export function updateDescription(params: UpdateDescriptionParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'update-description',
    functionArgs: [
      uintCV(params.campaignId),
      stringUtf8CV(params.newDescription),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// Read-only: getCampaignInfo
// ---------------------------------------------------------------------------

export interface CampaignInfo {
  owner: string;
  title: string;
  description: string;
  goal: number;
  raised: number;
  contributorsCount: number;
  startBlock: number;
  endBlock: number;
  claimed: boolean;
  refundsEnabled: boolean;
}

/**
 * Fetch full campaign details from on-chain state.
 *
 * Maps to:
 * ```clarity
 * (get-campaign (campaign-id uint))
 * ```
 */
export async function getCampaignInfo(campaignId: number): Promise<CampaignInfo | null> {
  const result = await readCrowdfund('get-campaign', [uintCV(campaignId)]);
  const json = cvToJSON(result);

  if (!json || json.value === null || json.type === 'none') {
    return null;
  }

  const v = json.value;
  return {
    owner: v.owner.value,
    title: v.title.value,
    description: v.description.value,
    goal: Number(v.goal.value),
    raised: Number(v.raised.value),
    contributorsCount: Number(v['contributors-count'].value),
    startBlock: Number(v['start-block'].value),
    endBlock: Number(v['end-block'].value),
    claimed: v.claimed.value,
    refundsEnabled: v['refunds-enabled'].value,
  };
}

// ---------------------------------------------------------------------------
// Read-only: getContributorInfo
// ---------------------------------------------------------------------------

/**
 * Fetch the total contribution of a specific address to a campaign.
 *
 * Maps to:
 * ```clarity
 * (get-contribution (campaign-id uint) (contributor principal))
 * ```
 */
export async function getContributorInfo(
  campaignId: number,
  contributorAddress: string,
): Promise<number> {
  const result = await readCrowdfund('get-contribution', [
    uintCV(campaignId),
    standardPrincipalCV(contributorAddress),
  ]);
  const json = cvToJSON(result);
  return Number(json.value);
}

// ---------------------------------------------------------------------------
// Read-only: isCampaignActive
// ---------------------------------------------------------------------------

/**
 * Check whether a campaign is still accepting contributions.
 *
 * Maps to:
 * ```clarity
 * (is-campaign-active (campaign-id uint))
 * ```
 */
export async function isCampaignActive(campaignId: number): Promise<boolean> {
  const result = await readCrowdfund('is-campaign-active', [uintCV(campaignId)]);
  const json = cvToJSON(result);
  return json.value === true;
}

// ---------------------------------------------------------------------------
// Read-only: isCampaignSuccessful
// ---------------------------------------------------------------------------

/**
 * Check whether a campaign reached its funding goal.
 *
 * Maps to:
 * ```clarity
 * (is-campaign-successful (campaign-id uint))
 * ```
 */
export async function isCampaignSuccessful(campaignId: number): Promise<boolean> {
  const result = await readCrowdfund('is-campaign-successful', [uintCV(campaignId)]);
  const json = cvToJSON(result);
  return json.value === true;
}

// ---------------------------------------------------------------------------
// Read-only: getProgressPercentage
// ---------------------------------------------------------------------------

/**
 * Get the funding progress as a percentage (0-100+).
 *
 * Maps to:
 * ```clarity
 * (get-progress-percentage (campaign-id uint))
 * ```
 */
export async function getProgressPercentage(campaignId: number): Promise<number> {
  const result = await readCrowdfund('get-progress-percentage', [uintCV(campaignId)]);
  const json = cvToJSON(result);
  return Number(json.value);
}

// ---------------------------------------------------------------------------
// Read-only: getCreatorStats
// ---------------------------------------------------------------------------

export interface CreatorStats {
  campaignsCreated: number;
  campaignsSuccessful: number;
  totalRaised: number;
}

/**
 * Fetch on-chain reputation stats for a campaign creator.
 *
 * Maps to:
 * ```clarity
 * (get-creator-stats (creator principal))
 * ```
 */
export async function getCreatorStats(address: string): Promise<CreatorStats> {
  const result = await readCrowdfund('get-creator-stats', [
    standardPrincipalCV(address),
  ]);
  const json = cvToJSON(result);
  const v = json.value;
  return {
    campaignsCreated: Number(v['campaigns-created'].value),
    campaignsSuccessful: Number(v['campaigns-successful'].value),
    totalRaised: Number(v['total-raised'].value),
  };
}

// ---------------------------------------------------------------------------
// Read-only: getBackerStats
// ---------------------------------------------------------------------------

export interface BackerStats {
  campaignsBacked: number;
  totalContributed: number;
}

/**
 * Fetch on-chain reputation stats for a campaign backer.
 *
 * Maps to:
 * ```clarity
 * (get-backer-stats (backer principal))
 * ```
 */
export async function getBackerStats(address: string): Promise<BackerStats> {
  const result = await readCrowdfund('get-backer-stats', [
    standardPrincipalCV(address),
  ]);
  const json = cvToJSON(result);
  const v = json.value;
  return {
    campaignsBacked: Number(v['campaigns-backed'].value),
    totalContributed: Number(v['total-contributed'].value),
  };
}

// ---------------------------------------------------------------------------
// Read-only: getPlatformStats
// ---------------------------------------------------------------------------

export interface PlatformStats {
  totalCampaigns: number;
  successfulCampaigns: number;
  totalRaised: number;
}

/**
 * Fetch global platform statistics.
 *
 * Maps to:
 * ```clarity
 * (get-platform-stats)
 * ```
 */
export async function getPlatformStats(): Promise<PlatformStats> {
  const result = await readCrowdfund('get-platform-stats', []);
  const json = cvToJSON(result);
  const v = json.value;
  return {
    totalCampaigns: Number(v['total-campaigns'].value),
    successfulCampaigns: Number(v['successful-campaigns'].value),
    totalRaised: Number(v['total-raised'].value),
  };
}

// ---------------------------------------------------------------------------
// Read-only: calculateFee
// ---------------------------------------------------------------------------

/**
 * Calculate the platform fee for a given amount.
 *
 * Maps to:
 * ```clarity
 * (calculate-fee (amount uint))
 * ```
 */
export async function calculateFee(amount: number): Promise<number> {
  const result = await readCrowdfund('calculate-fee', [uintCV(amount)]);
  const json = cvToJSON(result);
  return Number(json.value);
}

// ===========================================================================
// milestone-crowdfund.clar -- Milestone-based projects
// ===========================================================================

// ---------------------------------------------------------------------------
// createProject (milestone contract)
// ---------------------------------------------------------------------------

export interface CreateProjectParams {
  title: string;
  totalGoal: number;
  fundraiseDuration: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Create a new milestone-based project.
 *
 * Maps to:
 * ```clarity
 * (create-project (title (string-ascii 100))
 *                 (total-goal uint)
 *                 (fundraise-duration uint))
 * ```
 */
export function createProject(params: CreateProjectParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'create-project',
    functionArgs: [
      stringAsciiCV(params.title),
      uintCV(params.totalGoal),
      uintCV(params.fundraiseDuration),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// addMilestone
// ---------------------------------------------------------------------------

export interface AddMilestoneParams {
  projectId: number;
  title: string;
  description: string;
  amount: number;
  deadline: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Add a milestone to a project that is still in fundraising.
 *
 * Maps to:
 * ```clarity
 * (add-milestone (project-id uint)
 *               (title (string-ascii 100))
 *               (description (string-ascii 300))
 *               (amount uint)
 *               (deadline uint))
 * ```
 */
export function addMilestone(params: AddMilestoneParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'add-milestone',
    functionArgs: [
      uintCV(params.projectId),
      stringAsciiCV(params.title),
      stringAsciiCV(params.description),
      uintCV(params.amount),
      uintCV(params.deadline),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// backProject
// ---------------------------------------------------------------------------

export interface BackProjectParams {
  projectId: number;
  amount: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Back a milestone-based project with STX.
 *
 * Maps to:
 * ```clarity
 * (back-project (project-id uint) (amount uint))
 * ```
 */
export function backProject(params: BackProjectParams): void {
  const senderAddress = getCurrentAddress();
  if (!senderAddress) {
    throw new Error('Wallet not connected. Call connectWallet() first.');
  }

  const postConditions = [
    makeStandardSTXPostCondition(
      senderAddress,
      FungibleConditionCode.Equal,
      params.amount,
    ),
  ];

  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'back-project',
    functionArgs: [
      uintCV(params.projectId),
      uintCV(params.amount),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions,
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// submitMilestoneProof
// ---------------------------------------------------------------------------

export interface SubmitMilestoneProofParams {
  projectId: number;
  milestoneIndex: number;
  proofUrl: string;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Submit proof of milestone completion to trigger a backer vote.
 *
 * Maps to:
 * ```clarity
 * (submit-milestone-proof (project-id uint)
 *                         (milestone-index uint)
 *                         (proof-url (string-ascii 200)))
 * ```
 */
export function submitMilestoneProof(params: SubmitMilestoneProofParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'submit-milestone-proof',
    functionArgs: [
      uintCV(params.projectId),
      uintCV(params.milestoneIndex),
      stringAsciiCV(params.proofUrl),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// voteMilestone
// ---------------------------------------------------------------------------

export interface VoteMilestoneParams {
  projectId: number;
  milestoneIndex: number;
  /** true = approve, false = reject */
  approve: boolean;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Vote to approve or reject a submitted milestone.
 *
 * Maps to:
 * ```clarity
 * (vote-milestone (project-id uint)
 *                 (milestone-index uint)
 *                 (approve bool))
 * ```
 */
export function voteMilestone(params: VoteMilestoneParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'vote-milestone',
    functionArgs: [
      uintCV(params.projectId),
      uintCV(params.milestoneIndex),
      params.approve ? trueCV() : falseCV(),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// finalizeMilestone
// ---------------------------------------------------------------------------

export interface FinalizeMilestoneParams {
  projectId: number;
  milestoneIndex: number;
  onFinish?: (data: any) => void;
  onCancel?: () => void;
}

/**
 * Finalize a milestone vote. If approved the milestone amount is paid out
 * to the project creator; otherwise the milestone is marked rejected.
 *
 * Maps to:
 * ```clarity
 * (finalize-milestone (project-id uint) (milestone-index uint))
 * ```
 */
export function finalizeMilestone(params: FinalizeMilestoneParams): void {
  showContractCall({
    contractAddress: CONTRACT_ADDRESS,
    contractName: MILESTONE_CONTRACT,
    functionName: 'finalize-milestone',
    functionArgs: [
      uintCV(params.projectId),
      uintCV(params.milestoneIndex),
    ],
    network,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
    onFinish: params.onFinish,
    onCancel: params.onCancel,
  });
}

// ---------------------------------------------------------------------------
// Read-only: getProjectInfo (milestone contract)
// ---------------------------------------------------------------------------

export interface ProjectInfo {
  creator: string;
  title: string;
  totalGoal: number;
  totalRaised: number;
  milestonesCount: number;
  milestonesCompleted: number;
  /** 0=fundraising, 1=active, 2=completed, 3=failed */
  status: number;
  createdAt: number;
  endFundraise: number;
}

/**
 * Fetch project details from the milestone-crowdfund contract.
 *
 * Maps to:
 * ```clarity
 * (get-project (project-id uint))
 * ```
 */
export async function getProjectInfo(projectId: number): Promise<ProjectInfo | null> {
  const result = await readCrowdfund(
    'get-project',
    [uintCV(projectId)],
    MILESTONE_CONTRACT,
  );
  const json = cvToJSON(result);

  if (!json || json.value === null || json.type === 'none') {
    return null;
  }

  const v = json.value;
  return {
    creator: v.creator.value,
    title: v.title.value,
    totalGoal: Number(v['total-goal'].value),
    totalRaised: Number(v['total-raised'].value),
    milestonesCount: Number(v['milestones-count'].value),
    milestonesCompleted: Number(v['milestones-completed'].value),
    status: Number(v.status.value),
    createdAt: Number(v['created-at'].value),
    endFundraise: Number(v['end-fundraise'].value),
  };
}

// ---------------------------------------------------------------------------
// Read-only: getMilestoneInfo
// ---------------------------------------------------------------------------

export interface MilestoneInfo {
  title: string;
  description: string;
  amount: number;
  deadline: number;
  /** 0=locked, 1=voting, 2=approved, 3=rejected, 4=paid */
  status: number;
  votesApprove: number;
  votesReject: number;
  votingStarted: number;
  proofUrl: string;
}

/**
 * Fetch milestone details from on-chain state.
 *
 * Maps to:
 * ```clarity
 * (get-milestone (project-id uint) (milestone-index uint))
 * ```
 */
export async function getMilestoneInfo(
  projectId: number,
  milestoneIndex: number,
): Promise<MilestoneInfo | null> {
  const result = await readCrowdfund(
    'get-milestone',
    [uintCV(projectId), uintCV(milestoneIndex)],
    MILESTONE_CONTRACT,
  );
  const json = cvToJSON(result);

  if (!json || json.value === null || json.type === 'none') {
    return null;
  }

  const v = json.value;
  return {
    title: v.title.value,
    description: v.description.value,
    amount: Number(v.amount.value),
    deadline: Number(v.deadline.value),
    status: Number(v.status.value),
    votesApprove: Number(v['votes-approve'].value),
    votesReject: Number(v['votes-reject'].value),
    votingStarted: Number(v['voting-started'].value),
    proofUrl: v['proof-url'].value,
  };
}

// ---------------------------------------------------------------------------
// Read-only: getBackerInfo (milestone contract)
// ---------------------------------------------------------------------------

export interface BackerInfo {
  amount: number;
  votingPower: number;
  backedAt: number;
  refunded: boolean;
}

/**
 * Fetch a backer's record for a milestone-based project.
 *
 * Maps to:
 * ```clarity
 * (get-backer (project-id uint) (backer principal))
 * ```
 */
export async function getBackerInfo(
  projectId: number,
  backerAddress: string,
): Promise<BackerInfo | null> {
  const result = await readCrowdfund(
    'get-backer',
    [uintCV(projectId), standardPrincipalCV(backerAddress)],
    MILESTONE_CONTRACT,
  );
  const json = cvToJSON(result);

  if (!json || json.value === null || json.type === 'none') {
    return null;
  }

  const v = json.value;
  return {
    amount: Number(v.amount.value),
    votingPower: Number(v['voting-power'].value),
    backedAt: Number(v['backed-at'].value),
    refunded: v.refunded.value,
  };
}

// ---------------------------------------------------------------------------
// Read-only: hasVotedMilestone
// ---------------------------------------------------------------------------

/**
 * Check whether a specific address has already voted on a milestone.
 *
 * Maps to:
 * ```clarity
 * (has-voted-milestone (project-id uint) (milestone-index uint) (voter principal))
 * ```
 */
export async function hasVotedMilestone(
  projectId: number,
  milestoneIndex: number,
  voterAddress: string,
): Promise<boolean> {
  const result = await readCrowdfund(
    'has-voted-milestone',
    [
      uintCV(projectId),
      uintCV(milestoneIndex),
      standardPrincipalCV(voterAddress),
    ],
    MILESTONE_CONTRACT,
  );
  const json = cvToJSON(result);
  return json.value === true;
}

// ===========================================================================
// Advanced: programmatic transaction building (no wallet popup)
// ===========================================================================

/**
 * Build, sign, and broadcast a `contribute` transaction programmatically.
 * This bypasses the wallet popup and is intended for backend/script usage
 * where the caller has access to a private key.
 *
 * Demonstrates makeContractCall + broadcastTransaction from
 * @stacks/transactions.
 */
export async function contributeHeadless(
  campaignId: number,
  amount: number,
  senderKey: string,
): Promise<string> {
  const txOptions = {
    contractAddress: CONTRACT_ADDRESS,
    contractName: CROWDFUND_CONTRACT,
    functionName: 'contribute',
    functionArgs: [uintCV(campaignId), uintCV(amount)],
    senderKey,
    network,
    anchorMode: AnchorMode.Any,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [],
  };

  const transaction = await makeContractCall(txOptions);
  const broadcastResult = await broadcastTransaction(transaction, network);

  if ('error' in broadcastResult) {
    throw new Error(`Broadcast failed: ${broadcastResult.error} - ${broadcastResult.reason}`);
  }

  return broadcastResult.txid;
}

// ===========================================================================
// Re-exports for convenience
// ===========================================================================

export {
  // @stacks/connect re-exports
  AppConfig,
  UserSession,
  showConnect,
  showContractCall,
  // @stacks/transactions re-exports
  uintCV,
  principalCV,
  stringAsciiCV,
  stringUtf8CV,
  bufferCV,
  trueCV,
  falseCV,
  noneCV,
  someCV,
  tupleCV,
  listCV,
  cvToJSON,
  cvToString,
  AnchorMode,
  PostConditionMode,
  makeStandardSTXPostCondition,
  FungibleConditionCode,
  contractPrincipalCV,
  standardPrincipalCV,
  makeContractCall,
  callReadOnlyFunction,
  broadcastTransaction,
  // @stacks/network re-exports
  StacksMainnet,
};
