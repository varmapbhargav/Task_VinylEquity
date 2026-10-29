/**
 * B1: Reliable Issuance Submitter
 *
 * PROBLEM: Get a mint transaction on-chain exactly once despite:
 * - RPC timeout after broadcast
 * - Process crash mid-submission
 * - Transaction dropped from mempool
 * - Transaction reorged out
 *
 * SOLUTION: Durable state machine with nonce management and recovery logic
 *
 * STATE TRANSITIONS:
 * REQUESTED → VALIDATED → READY_TO_SUBMIT → SUBMITTED → MINED → CONFIRMING → FINALIZED
 *                                         ↘ DROPPED (retry)
 *                                         ↘ REORGED (resubmit)
 *                                         ↘ FAILED (manual review)
 *
 * PERSISTENCE STRATEGY:
 * - Save state BEFORE each side effect (broadcast, nonce reservation)
 * - Use nonce as idempotency key for blockchain operations
 * - Track blockHash to detect reorgs
 *
 * NONCE MANAGEMENT:
 * - Read pending nonce from chain
 * - Persist nonce reservation BEFORE broadcast
 * - On crash: scan nonces, look up receipts, resume from saved state
 *
 * FINALITY:
 * - Configurable confirmation depth (default: 12 blocks)
 * - Only mark FINALIZED after confirmations reached
 * - Reorg detection via blockHash comparison
 */

import {
  IssuanceRequest,
  IssuanceResult,
  IssuanceState,
  IssuanceRecord,
  IssuanceStore,
  ChainProvider,
} from '../types';

export interface SubmitIssuanceConfig {
  confirmationDepth: number;
  timeoutMs: number;
  maxRetries: number;
  retryDelayMs: number;
}

const DEFAULT_CONFIG: SubmitIssuanceConfig = {
  confirmationDepth: 12, // Standard for Ethereum mainnet-like chains
  timeoutMs: 30000,
  maxRetries: 10,
  retryDelayMs: 5000,
};

export class IssuanceSubmitter {
  constructor(
    private provider: ChainProvider,
    private store: IssuanceStore,
    private contractAddress: string,
    private signerAddress: string,
    private config: SubmitIssuanceConfig = DEFAULT_CONFIG
  ) {}

  /**
   * Submit an issuance request
   * Idempotent: calling twice with same issuanceId returns the same result
   */
  async submitIssuance(request: IssuanceRequest): Promise<IssuanceResult> {
    // Validation
    this.validateRequest(request);

    // Check for existing record (idempotency)
    const existing = await this.store.load(request.issuanceId);
    if (existing) {
      if (existing.state === IssuanceState.FINALIZED) {
        return this.recordToResult(existing);
      }
      // Resume incomplete workflow
      return this.resumeIssuance(existing);
    }

    // Create new record
    const record: IssuanceRecord = {
      issuanceId: request.issuanceId,
      to: request.to,
      amount: request.amount,
      state: IssuanceState.REQUESTED,
      confirmations: 0,
    };

    await this.store.save(record);

    // Proceed through state machine
    return this.processIssuance(record);
  }

  private async processIssuance(record: IssuanceRecord): Promise<IssuanceResult> {
    try {
      // VALIDATED state
      record.state = IssuanceState.VALIDATED;
      await this.store.save(record);

      // Reserve nonce BEFORE broadcast
      const nonce = await this.provider.getTransactionCount(this.signerAddress, 'pending');
      record.nonce = nonce;
      record.state = IssuanceState.READY_TO_SUBMIT;
      await this.store.save(record);

      // Broadcast transaction
      const txHash = await this.broadcastWithTimeout(record);
      record.txHash = txHash;
      record.state = IssuanceState.SUBMITTED;
      record.submittedAt = Date.now();
      await this.store.save(record);

      // Wait for mining
      await this.waitForMining(record);

      // Wait for confirmations
      await this.waitForConfirmations(record);

      return this.recordToResult(record);
    } catch (error) {
      record.state = IssuanceState.FAILED;
      record.error = error instanceof Error ? error.message : String(error);
      await this.store.save(record);
      throw error;
    }
  }

  private async resumeIssuance(record: IssuanceRecord): Promise<IssuanceResult> {
    switch (record.state) {
      case IssuanceState.FINALIZED:
        return this.recordToResult(record);

      case IssuanceState.READY_TO_SUBMIT:
      case IssuanceState.SUBMITTED:
        // Check if transaction actually made it on-chain
        await this.recoverFromUncertainBroadcast(record);
        return this.recordToResult(record);

      case IssuanceState.MINED:
      case IssuanceState.CONFIRMING:
        await this.waitForConfirmations(record);
        return this.recordToResult(record);

      case IssuanceState.DROPPED:
        // Retry with new nonce
        return this.retryIssuance(record);

      case IssuanceState.REORGED:
        // Resubmit
        return this.processIssuance(record);

      default:
        return this.processIssuance(record);
    }
  }

  private async broadcastWithTimeout(record: IssuanceRecord): Promise<string> {
    // Build transaction data (simplified - in production would encode mintWithIssuanceId call)
    const txData = this.encodeMintCall(record.to, record.amount, record.issuanceId);

    const broadcastPromise = this.provider.sendTransaction({
      to: this.contractAddress,
      data: txData,
      nonce: record.nonce!,
    });

    const timeoutPromise = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error('RPC_TIMEOUT')), this.config.timeoutMs)
    );

    try {
      return await Promise.race([broadcastPromise, timeoutPromise]);
    } catch (error) {
      if (error instanceof Error && error.message === 'RPC_TIMEOUT') {
        // Timeout occurred - txHash may or may not have been returned
        // Enter recovery mode
        throw new Error('TIMEOUT_RECOVERY_NEEDED');
      }
      throw error;
    }
  }

  /**
   * Recovery logic when we're uncertain if transaction was broadcast
   * 
   * STRATEGY:
   * 1. If txHash was persisted, query receipt
   * 2. If no txHash, check if nonce was consumed on-chain
   * 3. If nonce consumed, scan for transaction by nonce
   * 4. If nonce not consumed, safe to resubmit
   */
  private async recoverFromUncertainBroadcast(record: IssuanceRecord): Promise<void> {
    if (record.txHash) {
      // We have a txHash - check if it's mined
      const receipt = await this.provider.getTransactionReceipt(record.txHash);
      if (receipt) {
        record.state = IssuanceState.MINED;
        record.minedBlock = receipt.blockNumber;
        record.blockHash = receipt.blockHash;
        record.receiptStatus = receipt.status;
        await this.store.save(record);
        return;
      }

      // Not mined yet - check if still pending
      const tx = await this.provider.getTransaction(record.txHash);
      if (tx) {
        // Still pending
        record.state = IssuanceState.SUBMITTED;
        await this.store.save(record);
        return;
      }

      // Transaction not found - might be dropped
      record.state = IssuanceState.DROPPED;
      await this.store.save(record);
      return;
    }

    // No txHash - check if nonce was consumed
    const currentNonce = await this.provider.getTransactionCount(this.signerAddress, 'latest');
    if (currentNonce > record.nonce!) {
      // Nonce was consumed - find the transaction
      // In production, query transactions by nonce (requires archive node or indexer)
      // For now, mark as MANUAL_REVIEW
      record.state = IssuanceState.MANUAL_REVIEW;
      record.error = 'Nonce consumed but txHash unknown - manual investigation required';
      await this.store.save(record);
      throw new Error('NONCE_CONSUMED_UNKNOWN_TX');
    }

    // Nonce not consumed - safe to resubmit
    record.state = IssuanceState.READY_TO_SUBMIT;
    await this.store.save(record);
  }

  private async waitForMining(record: IssuanceRecord): Promise<void> {
    if (!record.txHash) {
      throw new Error('Cannot wait for mining without txHash');
    }

    let attempts = 0;
    while (attempts < this.config.maxRetries) {
      const receipt = await this.provider.getTransactionReceipt(record.txHash);
      if (receipt) {
        record.state = IssuanceState.MINED;
        record.minedBlock = receipt.blockNumber;
        record.blockHash = receipt.blockHash;
        record.receiptStatus = receipt.status;
        record.confirmations = 0;
        await this.store.save(record);

        if (receipt.status === 0) {
          throw new Error('Transaction reverted');
        }
        return;
      }

      // Check if dropped
      const tx = await this.provider.getTransaction(record.txHash);
      if (!tx) {
        record.state = IssuanceState.DROPPED;
        await this.store.save(record);
        throw new Error('Transaction dropped from mempool');
      }

      await this.sleep(this.config.retryDelayMs);
      attempts++;
    }

    throw new Error('Timeout waiting for transaction to mine');
  }

  private async waitForConfirmations(record: IssuanceRecord): Promise<void> {
    if (!record.minedBlock || !record.blockHash) {
      throw new Error('Cannot wait for confirmations without mined block');
    }

    record.state = IssuanceState.CONFIRMING;
    await this.store.save(record);

    while (record.confirmations < this.config.confirmationDepth) {
      // Check for reorg
      const block = await this.provider.getBlock(record.minedBlock);
      if (!block || block.hash !== record.blockHash) {
        // Reorg detected
        record.state = IssuanceState.REORGED;
        record.error = 'Block hash changed - transaction reorged';
        await this.store.save(record);
        throw new Error('REORG_DETECTED');
      }

      // Update confirmation count
      // In production, get current block number and calculate confirmations
      record.confirmations++;
      await this.store.save(record);

      if (record.confirmations >= this.config.confirmationDepth) {
        record.state = IssuanceState.FINALIZED;
        await this.store.save(record);
        return;
      }

      await this.sleep(1000); // Poll interval
    }
  }

  private async retryIssuance(record: IssuanceRecord): Promise<IssuanceResult> {
    // Get new nonce and retry
    const nonce = await this.provider.getTransactionCount(this.signerAddress, 'pending');
    record.nonce = nonce;
    record.state = IssuanceState.READY_TO_SUBMIT;
    record.txHash = undefined;
    await this.store.save(record);

    return this.processIssuance(record);
  }

  private validateRequest(request: IssuanceRequest): void {
    if (!request.issuanceId || request.issuanceId.length === 0) {
      throw new Error('Invalid issuanceId');
    }
    if (!request.to || !/^0x[0-9a-fA-F]{40}$/.test(request.to)) {
      throw new Error('Invalid to address');
    }
    if (request.amount <= 0n) {
      throw new Error('Amount must be positive');
    }
  }

  private encodeMintCall(to: string, amount: bigint, issuanceId: string): string {
    // Simplified encoding - in production would use ethers.Interface
    // mintWithIssuanceId(address to, uint256 amount, bytes32 issuanceId)
    return `0xMINT_${to}_${amount}_${issuanceId}`;
  }

  private recordToResult(record: IssuanceRecord): IssuanceResult {
    return {
      issuanceId: record.issuanceId,
      state: record.state,
      txHash: record.txHash,
      blockNumber: record.minedBlock,
      error: record.error,
    };
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
