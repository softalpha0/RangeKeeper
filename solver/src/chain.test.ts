import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeAbiParameters } from "viem";
import { toWad, toRawUnits, encodeRecenterProof } from "./chain.ts";

// These only exercise the pure encoding functions — no PRIVATE_KEY or
// VAULT_MANAGER_ADDRESS needed, so they run in CI with no secrets at all.
// Reading a pool's price is a plain `slot0()` view call (see chain.ts's
// readPoolPrice) — viem decodes that tuple itself, so there's no bit-packing
// logic of our own left to unit-test here.

test("toWad matches RiskMath.sol's WAD scale (1e18)", () => {
  assert.equal(toWad(1), 1_000_000_000_000_000_000n);
  assert.equal(toWad(0.5), 500_000_000_000_000_000n);
  assert.equal(toWad(0.065), 65_000_000_000_000_000n);
});

test("toRawUnits scales to the token's own decimals, not always 18", () => {
  // A real 6-decimal token (USDC/AUSD) is exactly the case toWad would get
  // catastrophically wrong (1e12x too large) if used here instead.
  assert.equal(toRawUnits(20, 6), 20_000_000n);
  assert.equal(toRawUnits(0.5, 6), 500_000n);
  // 18-decimal case still works the same as toWad would.
  assert.equal(toRawUnits(1, 18), toWad(1));
});

test("encodeRecenterProof round-trips through abi decode", () => {
  const dMin = toWad(0.047);
  const sigmaSqrtT = toWad(0.059);
  const sigma = toWad(0.05);
  const proof = encodeRecenterProof(dMin, sigmaSqrtT, sigma);

  const [decodedDMin, decodedSigmaSqrtT, decodedSigma] = decodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
    proof,
  );
  assert.equal(decodedDMin, dMin);
  assert.equal(decodedSigmaSqrtT, sigmaSqrtT);
  assert.equal(decodedSigma, sigma);
});
