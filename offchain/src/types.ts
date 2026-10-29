/**
 * TypeScript types for off-chain RWA tokenization modules
 * 
 * CRITICAL: All token amounts use bigint, NEVER number
 * Reason: JavaScript number has 53-bit precision; token amounts can exceed this
 */

// ============================================================================
// B1: Issuance Types
// ============================================================================

export interface IssuanceRequest {
  issuanceId: string;
  to: string;
  amount: bigint;
}

export enum IssuanceState {
  REQUESTED = 'REQUESTED',
  VALIDATED = 'VALIDATED',
  READY_TO_SUBMIT = 'READY_TO_SUBMIT',
  SUBMITTED = 'SUBMITTED',
  MINED = 'MINED',
  CONFIRMING = 'CONFIRMING',
  FINALIZED = 'FINALIZED',
  DROPPED = 'DROPPED',
  REORGED = 'REORGED',
  FAILED = 'FAILED',
  MANUAL_REVIEW = 'MANUAL_REVIEW',
}

export interface IssuanceRecord {
  issuanceId: string;
  to: string;
  amount: bigint;
  state: IssuanceState;
  nonce?: number;
  txHash?: string;
  submittedAt?: number;
  minedBlock?: number;
  blockHash?: string;
  confirmations: number;
  receiptStatus?: number;
  error?: string;
}

export interface IssuanceResult {
  issuanceId: string;
  state: IssuanceState;
  txHash?: string;
  blockNumber?: number;
  error?: string;
}

// ============================================================================
// B2: Reconciliation Types
// ============================================================================

export interface Authorization {
  authId: string;
  token: string;
  sender: string;
  recipient: string;
  amount: bigint;
  expiry: number;
}

export type TokenEventType = 'Transfer' | 'Mint' | 'Burn' | 'Freeze' | 'Unfreeze' | 'AuthorizationConsumed';

export interface DecodedTokenEvent {
  type: TokenEventType;
  transactionHash: string;
  logIndex: number;
  blockNumber: number;
  blockHash: string;
  from?: string;
  to?: string;
  value?: bigint;
  authId?: string;
}

export interface ReconcileState {
  balances: Map<string, bigint>;
  frozenAmounts: Map<string, bigint>;
  outstandingAuthorizations: Map<string, Authorization>;
  completedIssuances: Set<string>;
  confirmedAtBlock: number;
  canonicalHashes: Map<number, string>;
}

export interface EventBatch {
  events: DecodedTokenEvent[];
  headBlockNumber: number;
  canonicalHashes: Map<number, string>;
}

export enum DiscrepancyCategory {
  TRANSFER_WITHOUT_AUTHORIZATION = 'TRANSFER_WITHOUT_AUTHORIZATION',
  DUPLICATE_ISSUANCE = 'DUPLICATE_ISSUANCE',
  BALANCE_MISMATCH = 'BALANCE_MISMATCH',
  NON_CANONICAL_BLOCK = 'NON_CANONICAL_BLOCK',
  UNAUTHORIZED_MINT = 'UNAUTHORIZED_MINT',
  UNEXPECTED_BURN = 'UNEXPECTED_BURN',
}

export interface Discrepancy {
  category: DiscrepancyCategory;
  severity: 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL';
  transactionHash?: string;
  blockNumber: number;
  blockHash?: string;
  addresses?: string[];
  expected?: bigint;
  observed?: bigint;
  message: string;
}

export interface ReconcileResult {
  updatedState: ReconcileState;
  discrepancies: Discrepancy[];
}

// ============================================================================
// B3: Stock Split Types
// ============================================================================

export interface HolderPosition {
  address: string;
  balance: bigint;
}

export interface SplitResult {
  address: string;
  oldBalance: bigint;
  toMint: bigint;
  fractionalNumerator: bigint;
  fractionalDenominator: bigint;
}

export interface PlanSplitResult {
  results: SplitResult[];
  totalToMint: bigint;
  totalFractionalNumerator: bigint;
  fractionalDenominator: bigint;
}

// ============================================================================
// Persistence Interfaces
// ============================================================================

export interface IssuanceStore {
  save(record: IssuanceRecord): Promise<void>;
  load(issuanceId: string): Promise<IssuanceRecord | null>;
  findByNonce(nonce: number): Promise<IssuanceRecord[]>;
  list(): Promise<IssuanceRecord[]>;
}

// ============================================================================
// Provider Interfaces (for mocking)
// ============================================================================

export interface BlockWithTransactions {
  number: number;
  hash: string;
  timestamp: number;
  transactions: string[];
}

export interface TransactionReceipt {
  transactionHash: string;
  blockNumber: number;
  blockHash: string;
  status: number;
}

export interface ChainProvider {
  getTransactionCount(address: string, blockTag: 'latest' | 'pending'): Promise<number>;
  sendTransaction(tx: { to: string; data: string; nonce: number }): Promise<string>;
  getTransaction(txHash: string): Promise<{ hash: string; nonce: number } | null>;
  getTransactionReceipt(txHash: string): Promise<TransactionReceipt | null>;
  getBlock(blockNumber: number): Promise<BlockWithTransactions | null>;
  waitForTransaction(txHash: string, confirmations?: number): Promise<TransactionReceipt>;
}
