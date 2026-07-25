import { describe, expect, test } from "bun:test";
import { formatAboutUser, isSoulSectionKey } from "../src/user-profile";

describe("user-profile", () => {
  test("formats beliefs and goals into an about-the-user block", () => {
    const block = formatAboutUser({
      name: "Alex",
      languages: ["English"],
      soul: {
        Beliefs: "Honesty over comfort.",
        Goals: "Ship Omi.",
      },
    });
    expect(block).toContain("About the user:");
    expect(block).toContain("The user's name is Alex.");
    expect(block).toContain("User context — Beliefs:\nHonesty over comfort.");
  });

  test("recognizes soul section keys case-insensitively", () => {
    expect(isSoulSectionKey("beliefs")).toBe(true);
    expect(isSoulSectionKey("name")).toBe(false);
  });
});
