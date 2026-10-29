import { IssuanceRecord, IssuanceStore } from '../types';

/**
 * In-memory store for testing
 * Production would use PostgreSQL with Prisma
 */
export class InMemoryIssuanceStore implements IssuanceStore {
  private records: Map<string, IssuanceRecord> = new Map();

  async save(record: IssuanceRecord): Promise<void> {
    // Deep clone to prevent external mutation
    this.records.set(record.issuanceId, JSON.parse(JSON.stringify(record, this.bigIntReplacer)));
  }

  async load(issuanceId: string): Promise<IssuanceRecord | null> {
    const record = this.records.get(issuanceId);
    if (!record) return null;
    // Deep clone to prevent external mutation
    return JSON.parse(JSON.stringify(record, this.bigIntReplacer), this.bigIntReviver);
  }

  async findByNonce(nonce: number): Promise<IssuanceRecord[]> {
    const results: IssuanceRecord[] = [];
    for (const record of this.records.values()) {
      if (record.nonce === nonce) {
        results.push(JSON.parse(JSON.stringify(record, this.bigIntReplacer), this.bigIntReviver));
      }
    }
    return results;
  }

  async list(): Promise<IssuanceRecord[]> {
    return Array.from(this.records.values()).map((record) =>
      JSON.parse(JSON.stringify(record, this.bigIntReplacer), this.bigIntReviver)
    );
  }

  // Utility methods for bigint serialization
  private bigIntReplacer(key: string, value: any): any {
    if (typeof value === 'bigint') {
      return { __type: 'bigint', value: value.toString() };
    }
    return value;
  }

  private bigIntReviver(key: string, value: any): any {
    if (value && value.__type === 'bigint') {
      return BigInt(value.value);
    }
    return value;
  }

  // Test helper
  clear(): void {
    this.records.clear();
  }
}
