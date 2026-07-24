import { describe, expect, test } from "bun:test";
import {
  heuristicNeedsRefresh,
  minRegenerateIntervalMs,
  normalizeContentKind,
  staleCurrentAgeMs,
} from "../src/currents-refresh";

describe("currents refresh helpers", () => {
  test("normalizes mixed content kinds", () => {
    expect(normalizeContentKind("agent_action")).toBe("agent_action");
    expect(normalizeContentKind("human_action")).toBe("human_action");
    expect(normalizeContentKind("awareness")).toBe("awareness");
    expect(normalizeContentKind("review")).toBe("human_action");
  });

  test("heuristic refresh triggers when currents are stale", () => {
    const now = 1_000_000;
    const outcome = heuristicNeedsRefresh(
      {
        surfacedCount: 2,
        newestUpdatedAt: now - staleCurrentAgeMs - 1,
        memoryWatermark: 500,
        existingTitles: ["One", "Two"],
        memoryLines: [],
      },
      {
        last_checked_at: 0,
        last_regenerated_at: now - minRegenerateIntervalMs - 1,
        memory_watermark: 400,
      },
      now,
      false,
    );
    expect(outcome.refresh).toBe(true);
    expect(outcome.reason).toBe("currents_stale");
  });

  test("heuristic refresh skips fresh currents", () => {
    const now = 2_000_000;
    const outcome = heuristicNeedsRefresh(
      {
        surfacedCount: 1,
        newestUpdatedAt: now - 60_000,
        memoryWatermark: 500,
        existingTitles: ["Fresh"],
        memoryLines: [],
      },
      {
        last_checked_at: now - 1_000,
        last_regenerated_at: now - 60_000,
        memory_watermark: 500,
      },
      now,
      false,
    );
    expect(outcome.refresh).toBe(false);
    expect(outcome.reason).toBe("fresh");
  });

  test("parses mixed AI draft payloads", () => {
    const allowed = new Set(["ev-1", "ev-2"]);
    const parsed = JSON.parse(
      '{"items":[{"contentKind":"agent_action","title":"Draft reply","summary":"s","reason":"r","instruction":"i","evidenceId":"ev-1","tool":"assistant"},{"contentKind":"awareness","title":"Standup","summary":"s","reason":"r","instruction":"i","evidenceId":"ev-2"}]}',
    ) as { items: Array<Record<string, unknown>> };
    const drafts = parsed.items
      .filter((item) => allowed.has(String(item.evidenceId)))
      .map((item) => ({
        contentKind: normalizeContentKind(item.contentKind),
        title: String(item.title),
      }));
    expect(drafts).toEqual([
      { contentKind: "agent_action", title: "Draft reply" },
      { contentKind: "awareness", title: "Standup" },
    ]);
  });
});
