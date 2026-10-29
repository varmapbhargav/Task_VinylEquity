/**
 * Tests for B2: Reconciliation
 * 
 * Tests idempotency, confirmation depth, reorg handling, and discrepancy detection
 */

import {
  reconcile,
  checkBalances,
  CONFIRMATION_DEPTH,
} from './reconcile';
import {
  ReconcileState,
  EventBatch,
  DecodedTokenEvent,
  DiscrepancyCategory,
  Authorization,
} from '../types';

describe('B2: reconcile', () => {
  let initialState: ReconcileState;

  beforeEach(() => {
    initialState = {
      balances: new Map(),
      frozenAmounts: new Map(),
      outstandingAuthorizations: new Map(),
      completedIssuances: new Set(),
      confirmedAtBlock: 0,
      canonicalHashes: new Map(),
    };
  });

  test('HAPPY PATH: clean batch updates state correctly', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Mint',
          transactionHash: '0xabc',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          to: '0xalice',
          value: 1000n,
        },
        {
          type: 'Transfer',
          transactionHash: '0xdef',
          logIndex: 0,
          blockNumber: 101,
          blockHash: '0xblock101',
          from: '0xalice',
          to: '0xbob',
          value: 500n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([
        [100, '0xblock100'],
        [101, '0xblock101'],
      ]),
    };

    // Mark the mint as expected
    initialState.completedIssuances.add('0xabc');

    // Add authorization for transfer
    const auth: Authorization = {
      authId: 'auth-001',
      token: '0xtoken',
      sender: '0xalice',
      recipient: '0xbob',
      amount: 500n,
      expiry: Date.now() + 10000,
    };
    initialState.outstandingAuthorizations.set('0xalice:0xbob:500', auth);

    const result = reconcile(initialState, batch);

    // Check balances
    expect(result.updatedState.balances.get('0xalice')).toBe(500n);
    expect(result.updatedState.balances.get('0xbob')).toBe(500n);

    // No discrepancies
    expect(result.discrepancies).toHaveLength(0);

    // Confirmed block updated
    expect(result.updatedState.confirmedAtBlock).toBe(200 - CONFIRMATION_DEPTH);
  });

  test('TRANSFER WITHOUT AUTHORIZATION: detects discrepancy', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Transfer',
          transactionHash: '0xunauthorized',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          from: '0xalice',
          to: '0xbob',
          value: 1000n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([[100, '0xblock100']]),
    };

    // No authorization in state
    const result = reconcile(initialState, batch);

    // Should have one discrepancy
    expect(result.discrepancies).toHaveLength(1);
    expect(result.discrepancies[0].category).toBe(
      DiscrepancyCategory.TRANSFER_WITHOUT_AUTHORIZATION
    );
    expect(result.discrepancies[0].severity).toBe('HIGH');
    expect(result.discrepancies[0].transactionHash).toBe('0xunauthorized');
  });

  test('DUPLICATE ISSUANCE: detects when same issuanceId minted twice', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Mint',
          transactionHash: '0xmint1',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          to: '0xalice',
          value: 1000n,
        },
        {
          type: 'Mint',
          transactionHash: '0xmint1', // Same txHash = same issuanceId
          logIndex: 1,
          blockNumber: 101,
          blockHash: '0xblock101',
          to: '0xalice',
          value: 1000n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([
        [100, '0xblock100'],
        [101, '0xblock101'],
      ]),
    };

    initialState.completedIssuances.add('0xmint1');

    const result = reconcile(initialState, batch);

    // Should detect duplicate
    const duplicates = result.discrepancies.filter(
      (d) => d.category === DiscrepancyCategory.DUPLICATE_ISSUANCE
    );
    expect(duplicates.length).toBeGreaterThan(0);
  });

  test('UNAUTHORIZED MINT: detects mint without backend record', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Mint',
          transactionHash: '0xrogue',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          to: '0xmalicious',
          value: 9999n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([[100, '0xblock100']]),
    };

    // No expected issuance in state
    const result = reconcile(initialState, batch);

    // Should detect unauthorized mint
    expect(result.discrepancies).toHaveLength(1);
    expect(result.discrepancies[0].category).toBe(
      DiscrepancyCategory.UNAUTHORIZED_MINT
    );
    expect(result.discrepancies[0].severity).toBe('CRITICAL');
  });

  test('NON_CANONICAL_BLOCK: flags events from reorged blocks', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Transfer',
          transactionHash: '0xreorged',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xOLDblock100',
          from: '0xalice',
          to: '0xbob',
          value: 500n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([[100, '0xNEWblock100']]), // Different hash
    };

    const result = reconcile(initialState, batch);

    // Should flag non-canonical block
    expect(result.discrepancies).toHaveLength(1);
    expect(result.discrepancies[0].category).toBe(
      DiscrepancyCategory.NON_CANONICAL_BLOCK
    );

    // Should NOT apply event to state
    expect(result.updatedState.balances.get('0xalice')).toBeUndefined();
    expect(result.updatedState.balances.get('0xbob')).toBeUndefined();
  });

  test('IDEMPOTENT REPLAY: reprocessing same batch produces identical output', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Mint',
          transactionHash: '0xmint',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          to: '0xalice',
          value: 1000n,
        },
        {
          type: 'Transfer',
          transactionHash: '0xtransfer',
          logIndex: 0,
          blockNumber: 101,
          blockHash: '0xblock101',
          from: '0xalice',
          to: '0xbob',
          value: 300n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([
        [100, '0xblock100'],
        [101, '0xblock101'],
      ]),
    };

    initialState.completedIssuances.add('0xmint');
    const auth: Authorization = {
      authId: 'auth-001',
      token: '0xtoken',
      sender: '0xalice',
      recipient: '0xbob',
      amount: 300n,
      expiry: Date.now() + 10000,
    };
    initialState.outstandingAuthorizations.set('0xalice:0xbob:300', auth);

    // First reconciliation
    const result1 = reconcile(initialState, batch);

    // Second reconciliation with same batch
    const result2 = reconcile(result1.updatedState, batch);

    // State should not change
    expect(result2.updatedState.balances.get('0xalice')).toBe(
      result1.updatedState.balances.get('0xalice')
    );
    expect(result2.updatedState.balances.get('0xbob')).toBe(
      result1.updatedState.balances.get('0xbob')
    );

    // Same discrepancies (none in this case)
    expect(result2.discrepancies).toHaveLength(0);
  });

  test('UNCONFIRMED EVENTS: not applied to state', () => {
    const headBlock = 100;
    const unconfirmedBlock = headBlock - CONFIRMATION_DEPTH + 1;

    const batch: EventBatch = {
      events: [
        {
          type: 'Mint',
          transactionHash: '0xunconfirmed',
          logIndex: 0,
          blockNumber: unconfirmedBlock,
          blockHash: '0xblockX',
          to: '0xalice',
          value: 1000n,
        },
      ],
      headBlockNumber: headBlock,
      canonicalHashes: new Map([[unconfirmedBlock, '0xblockX']]),
    };

    const result = reconcile(initialState, batch);

    // Event should not be applied (not confirmed yet)
    expect(result.updatedState.balances.get('0xalice')).toBeUndefined();
  });

  test('BALANCE MISMATCH: checkBalances detects differences', () => {
    const state: ReconcileState = {
      balances: new Map([
        ['0xalice', 1000n],
        ['0xbob', 500n],
      ]),
      frozenAmounts: new Map(),
      outstandingAuthorizations: new Map(),
      completedIssuances: new Set(),
      confirmedAtBlock: 100,
      canonicalHashes: new Map(),
    };

    const onChainBalances = new Map([
      ['0xalice', 1000n], // Matches
      ['0xbob', 600n], // Mismatch
    ]);

    const discrepancies = checkBalances(state, onChainBalances);

    expect(discrepancies).toHaveLength(1);
    expect(discrepancies[0].category).toBe(DiscrepancyCategory.BALANCE_MISMATCH);
    expect(discrepancies[0].addresses).toEqual(['0xbob']);
    expect(discrepancies[0].expected).toBe(500n);
    expect(discrepancies[0].observed).toBe(600n);
  });

  test('EVENT ORDERING: events sorted by block number and log index', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Transfer',
          transactionHash: '0x3',
          logIndex: 1,
          blockNumber: 102,
          blockHash: '0xblock102',
          from: '0xalice',
          to: '0xcarol',
          value: 100n,
        },
        {
          type: 'Mint',
          transactionHash: '0x1',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          to: '0xalice',
          value: 1000n,
        },
        {
          type: 'Transfer',
          transactionHash: '0x2',
          logIndex: 0,
          blockNumber: 101,
          blockHash: '0xblock101',
          from: '0xalice',
          to: '0xbob',
          value: 200n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([
        [100, '0xblock100'],
        [101, '0xblock101'],
        [102, '0xblock102'],
      ]),
    };

    initialState.completedIssuances.add('0x1');
    // Add necessary authorizations
    initialState.outstandingAuthorizations.set('0xalice:0xbob:200', {
      authId: 'auth-1',
      token: '0xtoken',
      sender: '0xalice',
      recipient: '0xbob',
      amount: 200n,
      expiry: Date.now() + 10000,
    });
    initialState.outstandingAuthorizations.set('0xalice:0xcarol:100', {
      authId: 'auth-2',
      token: '0xtoken',
      sender: '0xalice',
      recipient: '0xcarol',
      amount: 100n,
      expiry: Date.now() + 10000,
    });

    const result = reconcile(initialState, batch);

    // Final balance should reflect correct order: mint 1000, transfer -200, transfer -100
    expect(result.updatedState.balances.get('0xalice')).toBe(700n);
    expect(result.updatedState.balances.get('0xbob')).toBe(200n);
    expect(result.updatedState.balances.get('0xcarol')).toBe(100n);
  });

  test('FREEZE/UNFREEZE: updates frozen amounts', () => {
    const batch: EventBatch = {
      events: [
        {
          type: 'Freeze',
          transactionHash: '0xfreeze',
          logIndex: 0,
          blockNumber: 100,
          blockHash: '0xblock100',
          from: '0xalice',
          value: 300n,
        },
        {
          type: 'Unfreeze',
          transactionHash: '0xunfreeze',
          logIndex: 0,
          blockNumber: 101,
          blockHash: '0xblock101',
          from: '0xalice',
          value: 100n,
        },
      ],
      headBlockNumber: 200,
      canonicalHashes: new Map([
        [100, '0xblock100'],
        [101, '0xblock101'],
      ]),
    };

    const result = reconcile(initialState, batch);

    // Net frozen: 300 - 100 = 200
    expect(result.updatedState.frozenAmounts.get('0xalice')).toBe(200n);
  });
});
