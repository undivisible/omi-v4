import { describe, expect, test } from "bun:test";
import {
  findDisallowedCrepusAction,
  findUnsafeCrepusImageUrl,
  isAllowedCrepusAction,
  isSafeCrepusImageUrl,
  validateCrepus,
} from "../src/crepus-safety";

describe("crepus safety", () => {
  test("allows the closed action verb set", () => {
    expect(isAllowedCrepusAction("complete")).toBe(true);
    expect(isAllowedCrepusAction("accept")).toBe(true);
    expect(isAllowedCrepusAction("prompt:Draft the reply")).toBe(true);
    expect(isAllowedCrepusAction("compute:Search my inbox")).toBe(true);
    expect(isAllowedCrepusAction("open:https://example.com/path")).toBe(true);
    expect(isAllowedCrepusAction("exec:rm -rf /")).toBe(false);
    expect(isAllowedCrepusAction("open:file:///etc/passwd")).toBe(false);
  });

  test("rejects unknown action verbs in a source document", () => {
    expect(
      findDisallowedCrepusAction(
        'button "Danger" onclick={exec:Delete everything}',
      ),
    ).toBe("Invalid crepus action: exec:Delete everything");
    expect(validateCrepus('button "Go" onclick={prompt:Draft it}').ok).toBe(
      true,
    );
    expect(validateCrepus('button "Go" onclick={eval:1+1}').ok).toBe(false);
  });

  test("rejects private and oversized image URLs", () => {
    expect(isSafeCrepusImageUrl("https://example.com/a.png")).toBe(true);
    expect(isSafeCrepusImageUrl("http://127.0.0.1/a.png")).toBe(false);
    expect(isSafeCrepusImageUrl("https://localhost/a.png")).toBe(false);
    expect(
      isSafeCrepusImageUrl(`https://example.com/${"a".repeat(3000)}`),
    ).toBe(false);
    expect(
      findUnsafeCrepusImageUrl("image src=http://127.0.0.1/logo.png alt=Logo"),
    ).toBe("Invalid crepus image URL: http://127.0.0.1/logo.png");
    expect(
      validateCrepus("image src=https://cdn.example.com/chart.png alt=Chart")
        .ok,
    ).toBe(true);
  });
});
