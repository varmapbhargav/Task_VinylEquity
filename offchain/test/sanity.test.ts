/**
 * Toolchain sanity test.
 *
 * Verifies the Jest + ts-jest + ES2022 target pipeline actually runs, and that
 * arbitrary-precision integer arithmetic (the only arithmetic permitted for token
 * amounts anywhere in this project) behaves exactly. It asserts no business logic.
 */
describe('offchain toolchain sanity', () => {
  it('runs TypeScript through ts-jest', () => {
    const doubled: (n: bigint) => bigint = (n) => n * 2n;
    expect(doubled(21n)).toBe(42n);
  });

  it('represents token-scale integers exactly (no floating-point drift)', () => {
    const totalSupply = 10n ** 30n; // 1e30 base units
    expect(totalSupply / 2n).toBe(5n * 10n ** 29n);
    // The same value is not exactly representable as a JS number.
    expect(Number.isSafeInteger(Number(totalSupply))).toBe(false);
  });
});
