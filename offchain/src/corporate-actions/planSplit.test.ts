/**
 * Tests for B3: Stock Split Calculator
 * 
 * Tests conservation invariant, exact entitlement, and fractional handling
 */

import {
  planSplit,
  verifyConservation,
  verifyNoOverpayment,
} from './planSplit';
import { HolderPosition } from '../types';

describe('B3: planSplit', () => {
  test('EVEN BALANCE (4): clean split with no fractional', () => {
    const holders: HolderPosition[] = [
      { address: '0xalice', balance: 4n },
    ];

    const result = planSplit(holders, 3n, 2n);

    // 4 * 3 / 2 = 6 whole tokens, 0 remainder
    // toMint = 6 - 4 = 2
    expect(result.results[0].oldBalance).toBe(4n);
    expect(result.results[0].toMint).toBe(2n);
    expect(result.results[0].fractionalNumerator).toBe(0n);
    expect(result.results[0].fractionalDenominator).toBe(2n);

    // Aggregates
    expect(result.totalToMint).toBe(2n);
    expect(result.totalFractionalNumerator).toBe(0n);

    // Conservation
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('ODD BALANCE (5): produces fractional entitlement', () => {
    const holders: HolderPosition[] = [
      { address: '0xbob', balance: 5n },
    ];

    const result = planSplit(holders, 3n, 2n);

    // 5 * 3 = 15
    // 15 / 2 = 7 whole (floor), remainder 1
    // toMint = 7 - 5 = 2
    expect(result.results[0].oldBalance).toBe(5n);
    expect(result.results[0].toMint).toBe(2n);
    expect(result.results[0].fractionalNumerator).toBe(1n);
    expect(result.results[0].fractionalDenominator).toBe(2n);

    expect(result.totalToMint).toBe(2n);
    expect(result.totalFractionalNumerator).toBe(1n);

    // Conservation: 5*3 = (5+2)*2 + 1 → 15 = 14 + 1 ✓
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('SINGLE TOKEN (1): floor rounds down, creates fractional', () => {
    const holders: HolderPosition[] = [
      { address: '0xcarol', balance: 1n },
    ];

    const result = planSplit(holders, 3n, 2n);

    // 1 * 3 = 3
    // 3 / 2 = 1 whole (floor), remainder 1
    // toMint = 1 - 1 = 0
    expect(result.results[0].oldBalance).toBe(1n);
    expect(result.results[0].toMint).toBe(0n);
    expect(result.results[0].fractionalNumerator).toBe(1n);

    // Conservation: 1*3 = (1+0)*2 + 1 → 3 = 2 + 1 ✓
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('ZERO BALANCE: no tokens minted', () => {
    const holders: HolderPosition[] = [
      { address: '0xdave', balance: 0n },
    ];

    const result = planSplit(holders, 3n, 2n);

    expect(result.results[0].toMint).toBe(0n);
    expect(result.results[0].fractionalNumerator).toBe(0n);

    expect(result.totalToMint).toBe(0n);
    expect(result.totalFractionalNumerator).toBe(0n);

    expect(verifyConservation(result, 3n, 2n)).toBe(true);
  });

  test('LARGE BALANCE (2^64): no overflow with BigInt', () => {
    const largeBalance = 2n ** 64n;
    const holders: HolderPosition[] = [
      { address: '0xwhale', balance: largeBalance },
    ];

    // Should not throw overflow
    const result = planSplit(holders, 3n, 2n);

    // Expected: (2^64 * 3) / 2 = 2^64 * 1.5 = 2^63 * 3
    const expected = (largeBalance * 3n) / 2n;
    const toMint = expected - largeBalance;

    expect(result.results[0].toMint).toBe(toMint);

    // Conservation must hold
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('MULTIPLE HOLDERS: mixed even/odd balances', () => {
    const holders: HolderPosition[] = [
      { address: '0xalice', balance: 4n },
      { address: '0xbob', balance: 5n },
      { address: '0xcarol', balance: 3n },
      { address: '0xdave', balance: 0n },
    ];

    const result = planSplit(holders, 3n, 2n);

    // Alice: 4*3=12, 12/2=6, toMint=2, remainder=0
    expect(result.results[0].toMint).toBe(2n);
    expect(result.results[0].fractionalNumerator).toBe(0n);

    // Bob: 5*3=15, 15/2=7, toMint=2, remainder=1
    expect(result.results[1].toMint).toBe(2n);
    expect(result.results[1].fractionalNumerator).toBe(1n);

    // Carol: 3*3=9, 9/2=4, toMint=1, remainder=1
    expect(result.results[2].toMint).toBe(1n);
    expect(result.results[2].fractionalNumerator).toBe(1n);

    // Dave: 0
    expect(result.results[3].toMint).toBe(0n);
    expect(result.results[3].fractionalNumerator).toBe(0n);

    // Aggregates
    expect(result.totalToMint).toBe(5n);
    expect(result.totalFractionalNumerator).toBe(2n);

    // Conservation
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('CONSERVATION: old supply * 3/2 = new supply + fractional', () => {
    const holders: HolderPosition[] = [
      { address: '0xalice', balance: 10n },
      { address: '0xbob', balance: 7n },
      { address: '0xcarol', balance: 3n },
    ];

    const result = planSplit(holders, 3n, 2n);

    const oldTotalSupply = 10n + 7n + 3n; // 20
    const newTotalSupply = oldTotalSupply + result.totalToMint; // 20 + 10 = 30

    // Conservation: 20*3 = 30*2 + fractional
    // 60 = 60 + fractional
    // fractional must be 0
    const leftSide = oldTotalSupply * 3n;
    const rightSide = newTotalSupply * 2n + result.totalFractionalNumerator;

    expect(leftSide).toBe(rightSide);
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
  });

  test('NO OVERPAYMENT: each holder gets exact entitlement (floor)', () => {
    const holders: HolderPosition[] = [
      { address: '0xalice', balance: 7n }, // 7*3=21, 21/2=10, remainder=1
      { address: '0xbob', balance: 11n }, // 11*3=33, 33/2=16, remainder=1
    ];

    const result = planSplit(holders, 3n, 2n);

    // Verify each holder's calculation
    for (const splitResult of result.results) {
      const entitlement = splitResult.oldBalance * 3n;
      const wholeNew = splitResult.oldBalance + splitResult.toMint;
      const reconstructed = wholeNew * 2n + splitResult.fractionalNumerator;

      expect(entitlement).toBe(reconstructed);
      expect(splitResult.fractionalNumerator).toBeLessThan(2n);
    }

    expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
  });

  test('VALIDATION: rejects invalid ratios', () => {
    const holders: HolderPosition[] = [{ address: '0xalice', balance: 10n }];

    // Zero numerator
    expect(() => planSplit(holders, 0n, 2n)).toThrow('Numerator must be positive');

    // Zero denominator
    expect(() => planSplit(holders, 3n, 0n)).toThrow('Denominator must be positive');

    // Ratio that doesn't increase supply (1:2 would decrease)
    expect(() => planSplit(holders, 1n, 2n)).toThrow('Split must increase supply');

    // Equal ratio (no actual split)
    expect(() => planSplit(holders, 2n, 2n)).toThrow('Split must increase supply');
  });

  test('EDGE CASE: very small fractional (1 holder with balance 1)', () => {
    const holders: HolderPosition[] = [
      { address: '0xminnow', balance: 1n },
    ];

    const result = planSplit(holders, 3n, 2n);

    // 1*3 = 3, 3/2 = 1 whole, remainder 1
    // Holder keeps 1 token, gets 0 new, has 1/2 fractional claim
    expect(result.results[0].toMint).toBe(0n);
    expect(result.results[0].fractionalNumerator).toBe(1n);

    // Even this edge case conserves
    expect(verifyConservation(result, 3n, 2n)).toBe(true);
  });

  test('DIFFERENT RATIO (5:3): still conserves', () => {
    const holders: HolderPosition[] = [
      { address: '0xalice', balance: 9n }, // 9*5=45, 45/3=15, toMint=6, remainder=0
      { address: '0xbob', balance: 10n }, // 10*5=50, 50/3=16, toMint=6, remainder=2
    ];

    const result = planSplit(holders, 5n, 3n);

    expect(result.results[0].toMint).toBe(6n);
    expect(result.results[0].fractionalNumerator).toBe(0n);

    expect(result.results[1].toMint).toBe(6n);
    expect(result.results[1].fractionalNumerator).toBe(2n);

    expect(verifyConservation(result, 5n, 3n)).toBe(true);
    expect(verifyNoOverpayment(result, 5n, 3n)).toBe(true);
  });

  test('PROPERTY: conservation holds for ANY holder list', () => {
    // Random holder lists
    const testCases = [
      [1n, 2n, 3n, 4n, 5n],
      [100n, 200n, 300n],
      [1n],
      [999n, 1n, 50n, 27n],
      [0n, 0n, 0n],
    ];

    for (const balances of testCases) {
      const holders = balances.map((balance, i) => ({
        address: `0x${i}`,
        balance,
      }));

      const result = planSplit(holders, 3n, 2n);

      expect(verifyConservation(result, 3n, 2n)).toBe(true);
      expect(verifyNoOverpayment(result, 3n, 2n)).toBe(true);
    }
  });
});
