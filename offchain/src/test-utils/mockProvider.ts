/**
 * Mock Chain Provider for testing
 * Simulates blockchain behavior including timeouts, reorgs, and dropped transactions
 */

import {
  ChainProvider,
  BlockWithTransactions,
  TransactionReceipt,
} from '../types';

interface Transaction {
  hash: string;
  nonce: number;
  to: string;
  data: string;
  blockNumber?: number;
  blockHash?: string;
}

export class MockChainProvider implements ChainProvider {
  private nonce: number = 0;
  private transactions: Map<string, Transaction> = new Map();
  private receipts: Map<string, TransactionReceipt> = new Map();
  private blocks: Map<number, BlockWithTransactions> = new Map();
  private currentBlockNumber: number = 1000;
  
  // Test controls
  public shouldTimeout: boolean = false;
  public shouldDropTransaction: boolean = false;
  public reorgAtBlock?: number;
  public reorgNewHash?: string;

  async getTransactionCount(
    address: string,
    blockTag: 'latest' | 'pending'
  ): Promise<number> {
    return this.nonce;
  }

  async sendTransaction(tx: { to: string; data: string; nonce: number }): Promise<string> {
    if (this.shouldTimeout) {
      // Simulate timeout - throw after delay
      await new Promise((resolve) => setTimeout(resolve, 100));
      throw new Error('RPC_TIMEOUT');
    }

    const txHash = `0x${Math.random().toString(16).substring(2)}`;
    
    this.transactions.set(txHash, {
      hash: txHash,
      nonce: tx.nonce,
      to: tx.to,
      data: tx.data,
    });

    // Consume nonce
    if (tx.nonce >= this.nonce) {
      this.nonce = tx.nonce + 1;
    }

    return txHash;
  }

  async getTransaction(txHash: string): Promise<{ hash: string; nonce: number } | null> {
    const tx = this.transactions.get(txHash);
    if (!tx) return null;

    // If dropped, return null
    if (this.shouldDropTransaction && !tx.blockNumber) {
      return null;
    }

    return { hash: tx.hash, nonce: tx.nonce };
  }

  async getTransactionReceipt(txHash: string): Promise<TransactionReceipt | null> {
    return this.receipts.get(txHash) || null;
  }

  async getBlock(blockNumber: number): Promise<BlockWithTransactions | null> {
    // Handle reorg
    if (this.reorgAtBlock && blockNumber === this.reorgAtBlock && this.reorgNewHash) {
      const block = this.blocks.get(blockNumber);
      if (block) {
        return { ...block, hash: this.reorgNewHash };
      }
    }

    return this.blocks.get(blockNumber) || null;
  }

  async waitForTransaction(
    txHash: string,
    confirmations?: number
  ): Promise<TransactionReceipt> {
    const receipt = this.receipts.get(txHash);
    if (!receipt) {
      throw new Error('Transaction not found');
    }
    return receipt;
  }

  // Test helpers

  /**
   * Mine a pending transaction
   */
  mineTransaction(txHash: string, status: number = 1): void {
    const tx = this.transactions.get(txHash);
    if (!tx) {
      throw new Error('Transaction not found');
    }

    this.currentBlockNumber++;
    const blockHash = `0xblock${this.currentBlockNumber}`;

    tx.blockNumber = this.currentBlockNumber;
    tx.blockHash = blockHash;

    const receipt: TransactionReceipt = {
      transactionHash: txHash,
      blockNumber: this.currentBlockNumber,
      blockHash: blockHash,
      status: status,
    };

    this.receipts.set(txHash, receipt);

    // Create block
    this.blocks.set(this.currentBlockNumber, {
      number: this.currentBlockNumber,
      hash: blockHash,
      timestamp: Date.now(),
      transactions: [txHash],
    });
  }

  /**
   * Drop a transaction from mempool
   */
  dropTransaction(txHash: string): void {
    this.transactions.delete(txHash);
  }

  /**
   * Simulate a reorg by changing block hash
   */
  simulateReorg(blockNumber: number, newHash: string): void {
    const block = this.blocks.get(blockNumber);
    if (block) {
      this.blocks.set(blockNumber, { ...block, hash: newHash });
    }

    // Update receipts
    for (const [txHash, receipt] of this.receipts.entries()) {
      if (receipt.blockNumber === blockNumber) {
        this.receipts.set(txHash, { ...receipt, blockHash: newHash });
      }
    }
  }

  /**
   * Reset provider state
   */
  reset(): void {
    this.nonce = 0;
    this.transactions.clear();
    this.receipts.clear();
    this.blocks.clear();
    this.currentBlockNumber = 1000;
    this.shouldTimeout = false;
    this.shouldDropTransaction = false;
    this.reorgAtBlock = undefined;
    this.reorgNewHash = undefined;
  }

  /**
   * Get current block number
   */
  getCurrentBlockNumber(): number {
    return this.currentBlockNumber;
  }

  /**
   * Advance block number without mining
   */
  advanceBlocks(count: number): void {
    this.currentBlockNumber += count;
  }
}
