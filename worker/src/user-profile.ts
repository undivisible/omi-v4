export const soulSections = [
  "Identity",
  "Goals",
  "Work",
  "Preferences",
  "Routines",
  "Beliefs",
  "Constraints",
  "People",
  "Health",
  "Context",
] as const;

const stableSoulSections = new Set([
  "Identity",
  "Goals",
  "Preferences",
  "Beliefs",
  "Constraints",
]);

export const isSoulSectionKey = (key: string): boolean =>
  soulSections.some(
    (section) => section.toLowerCase() === key.trim().toLowerCase(),
  );

export const soulSectionStability = (section: string): "stable" | "current" =>
  stableSoulSections.has(section) ? "stable" : "current";

export type AboutUserInput = {
  name?: string | null;
  languages?: readonly string[];
  soul?: Readonly<Record<string, string>>;
};

export const formatAboutUser = (input: AboutUserInput): string | null => {
  const facts: string[] = [];
  const name = input.name?.trim();
  if (name) facts.push(`The user's name is ${name}.`);
  const languages = (input.languages ?? []).filter((value) => value.trim());
  if (languages.length > 0) {
    facts.push(`The user's preferred languages: ${languages.join(", ")}.`);
  }
  for (const section of soulSections) {
    const text = input.soul?.[section]?.trim();
    if (text) facts.push(`User context — ${section}:\n${text}`);
  }
  if (facts.length === 0) return null;
  return `About the user:\n${facts.join("\n")}`;
};
