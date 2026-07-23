// Server-side price band for the BYOK negotiation. This module is the single
// source of truth for what a BYOK subscription may cost: the standard price,
// the hard floor, and the finite set of concessions the negotiator is allowed
// to grant. Nothing here is reachable from the client, and no price value is
// ever accepted from a request body or from raw model output.
//
// Every value is env-overridable so pricing can move without a code change,
// but a misconfigured override is rejected rather than applied: an override
// that would invert the band or push the floor to zero falls back to the
// compiled default.

import type { Bindings } from "./types";

export type ConcessionCode =
  | "annual_commitment"
  | "own_inference"
  | "case_study"
  | "student"
  | "early_adopter";

export type Concession = {
  code: ConcessionCode;
  centsOff: number;
  label: string;
};

export type PriceBand = {
  standardCents: number;
  floorCents: number;
  maxTurns: number;
  cooldownMs: number;
  concessions: Concession[];
};

// The concessions the negotiator may grant, and what each is worth. A code
// that is not in this table can never move the price, whatever the model
// returns.
const defaultConcessions: Concession[] = [
  {
    code: "own_inference",
    centsOff: 150,
    label: "you pay for your own inference",
  },
  {
    code: "annual_commitment",
    centsOff: 200,
    label: "you commit for a year",
  },
  {
    code: "case_study",
    centsOff: 100,
    label: "you are happy to be written about",
  },
  { code: "student", centsOff: 150, label: "you are a student" },
  {
    code: "early_adopter",
    centsOff: 100,
    label: "you joined early and report bugs",
  },
];

const defaultBand: PriceBand = {
  standardCents: 1200,
  floorCents: 700,
  maxTurns: 6,
  cooldownMs: 30 * 24 * 60 * 60_000,
  concessions: defaultConcessions,
};

const integer = (
  value: string | undefined,
  minimum: number,
  maximum: number,
): number | null => {
  const parsed = Number(value?.trim());
  return Number.isSafeInteger(parsed) && parsed >= minimum && parsed <= maximum
    ? parsed
    : null;
};

// Per-concession overrides arrive as a JSON object of known code -> cents.
// Unknown codes are dropped rather than honoured, so an override can never
// invent a new lever for the model to pull.
const overriddenConcessions = (raw: string | undefined): Concession[] => {
  if (!raw?.trim()) return defaultConcessions;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return defaultConcessions;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
    return defaultConcessions;
  const overrides = parsed as Record<string, unknown>;
  return defaultConcessions.map((concession) => {
    const value = overrides[concession.code];
    return typeof value === "number" &&
      Number.isSafeInteger(value) &&
      value >= 0 &&
      value <= 100_000
      ? { ...concession, centsOff: value }
      : concession;
  });
};

export const priceBand = (env: Bindings): PriceBand => {
  const standardCents =
    integer(env.BYOK_STANDARD_PRICE_CENTS, 1, 1_000_000) ??
    defaultBand.standardCents;
  const floorCandidate =
    integer(env.BYOK_FLOOR_PRICE_CENTS, 1, 1_000_000) ?? defaultBand.floorCents;
  // A floor above the standard price is a misconfiguration, not a discount
  // ceiling; refuse it and keep the band closed.
  const floorCents =
    floorCandidate <= standardCents ? floorCandidate : standardCents;
  const cooldownHours =
    integer(env.BYOK_NEGOTIATION_COOLDOWN_HOURS, 0, 24 * 365) ?? null;
  return {
    standardCents,
    floorCents,
    maxTurns: integer(env.BYOK_NEGOTIATION_MAX_TURNS, 1, 24) ?? 6,
    cooldownMs:
      cooldownHours === null
        ? defaultBand.cooldownMs
        : cooldownHours * 3600_000,
    concessions: overriddenConcessions(env.BYOK_NEGOTIATION_CONCESSIONS),
  };
};

export const concessionFor = (
  band: PriceBand,
  code: unknown,
): Concession | null =>
  typeof code === "string"
    ? (band.concessions.find((entry) => entry.code === code) ?? null)
    : null;

// The one function that turns granted concessions into money. Grants are
// de-duplicated and the result is clamped into the band, so no combination of
// grants -- including a replayed or forged list -- can land below the floor.
export const priceForGrants = (
  band: PriceBand,
  grants: readonly string[],
): number => {
  const applied = new Set<string>();
  let price = band.standardCents;
  for (const grant of grants) {
    const concession = concessionFor(band, grant);
    if (!concession || applied.has(concession.code)) continue;
    applied.add(concession.code);
    price -= concession.centsOff;
  }
  return Math.min(band.standardCents, Math.max(band.floorCents, price));
};

export const normalizeGrants = (
  band: PriceBand,
  grants: readonly unknown[],
): ConcessionCode[] => {
  const applied: ConcessionCode[] = [];
  for (const grant of grants) {
    const concession = concessionFor(band, grant);
    if (concession && !applied.includes(concession.code))
      applied.push(concession.code);
  }
  return applied;
};

export const formatPrice = (cents: number): string =>
  `$${(cents / 100).toFixed(2)}`;
