/**
 * B3: Stock Split Calculator
 *
 * PROBLEM: Token has 0 decimals (indivisible units). 3-for-2 split creates fractional entitlements.
 *
 * ARITHMETIC:
 * - For holder with balance q:
 *   - newEntitlement = q * 3 (exact, checked for overflow)
 *   - wholeTokens = newEntitlement / 2 (floor division)
 *   - toMint = wholeTokens - q (net new tokens to mint)
 *   - fractional = newEntitlement % 2 (remainder: 0 or 1)
 *
 * ROUNDING RULE: Floor division (Solidity/TypeScript default)
 * - No silent rounding up
 * - Fractional entitlements explicitly tracked
 * - Policy for fractional settlement (cash-in-lieu, etc.) separate from calculation
 *
 * CONSERVATION INVARIANT:
 * sum(oldBalance * 3) = sum(newBalance * 2) + sum(fractionalNumerator)
 * where newBalance = oldBalance + toMint
 *
 * EXAMPLES (3:2 split):
 * - balance=4: newEntitlement=12, whole=6, toMint=2, fractional=0
 * - balance=5: newEntitlement=15, whole=7, toMint=2, fractional=1
 * - balance=1: newEntitlement=3, whole=1, toMint=0, fractional=1
 * - balance=0: newEntitlement=0, whole=0, toMint=0, fractional=0
 */

import { HolderPosition, SplitResult, PlanSplitResult } from '../types';

export function planSplit(
  holders: HolderPosition[],
  numerator: bigint,
  denominator: bigint
): PlanSplitResult {
  // Validation
  if (numerator <= 0n) {
    throw new Error('Numerator must be positive');
  }
  if (denominator <= 0n) {
    throw new Error('Denominator must be positive');
  }
  if (numerator <= denominator) {
    throw new Error('Split must increase supply (numerator > denominator)');
  }

  const results: SplitResult[] = [];
  let totalToMint = 0n;
  let totalFractionalNumerator = 0n;

  for (const holder of holders) {
    if (holder.balance < 0n) {
      throw new Error(`Invalid balance for ${holder.address}: ${holder.balance}`);
    }

    // Skip zero balances
    if (holder.balance === 0n) {
      results.push({
        address: holder.address,
        oldBalance: 0n,
        toMint: 0n,
        fractionalNumerator: 0n,
        fractionalDenominator: denominator,
      });
      continue;
    }

    // Compute new entitlement (checked math - will throw on overflow)
    const newEntitlement = holder.balance * numerator;

    // Floor division for whole tokens
    const wholeNewBalance = newEntitlement / denominator;

    // Net tokens to mint
    const toMint = wholeNewBalance - holder.balance;

    // Fractional remainder
    const fractionalNumerator = newEntitlement % denominator;

    results.push({
      address: holder.address,
      oldBalance: holder.balance,
      toMint: toMint,
      fractionalNumerator: fractionalNumerator,
      fractionalDenominator: denominator,
    });

    // Aggregate
    totalToMint += toMint;
    totalFractionalNumerator += fractionalNumerator;
  }

  return {
    results,
    totalToMint,
    totalFractionalNumerator,
    fractionalDenominator: denominator,
  };
}

/**
 * Verify conservation invariant
 * 
 * INVARIANT: sum(oldBalance * numerator) = sum((oldBalance + toMint) * denominator) + sum(fractionalNumerator)
 * 
 * Simplified: sum(oldBalance * numerator) = sum(newBalance * denominator) + sum(fractionalNumerator)
 * 
 * This MUST hold for any holder list and any ratio
 */
export function verifyConservation(
  planResult: PlanSplitResult,
  numerator: bigint,
  denominator: bigint
): boolean {
  let leftSide = 0n;
  let rightSideWhole = 0n;
  let rightSideFractional = 0n;

  for (const result of planResult.results) {
    // Left side: old supply scaled by numerator
    leftSide += result.oldBalance * numerator;

    // Right side: new supply scaled by denominator + fractional remainder
    const newBalance = result.oldBalance + result.toMint;
    rightSideWhole += newBalance * denominator;
    rightSideFractional += result.fractionalNumerator;
  }

  const rightSide = rightSideWhole + rightSideFractional;

  return leftSide === rightSide;
}

/**
 * Verify no holder gets more than their exact entitlement
 * 
 * For each holder:
 * - oldBalance * numerator = (oldBalance + toMint) * denominator + fractionalNumerator
 * - This ensures toMint is the floor of the exact entitlement
 */
export function verifyNoOverpayment(
  planResult: PlanSplitResult,
  numerator: bigint,
  denominator: bigint
): boolean {
  for (const result of planResult.results) {
    const leftSide = result.oldBalance * numerator;
    const rightSide =
      (result.oldBalance + result.toMint) * denominator + result.fractionalNumerator;

    if (leftSide !== rightSide) {
      return false;
    }

    // Additionally verify fractional is less than denominator (0 or 1 for 3:2)
    if (result.fractionalNumerator >= denominator) {
      return false;
    }
  }

  return true;
}
