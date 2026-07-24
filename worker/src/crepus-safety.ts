// Defense-in-depth for AI-authored `.crepus` stored by the worker. The client
// renderer is the primary boundary; this mirrors `dispatchCrepusAction` in
// `app/lib/currents/crepus_current.dart` and rejects hostile sources early.

export const crepusMaxLen = 8000;

const crepusImageUrlMaxLen = 2000;

const blockedImageHosts = new Set([
  "localhost",
  "127.0.0.1",
  "0.0.0.0",
  "::1",
  "[::1]",
]);

const crepusEventPattern =
  /\bon(?:click|change|long-?press|long_?press)[_-]?=\s*(?:"((?:\\.|[^"\\])*)"|(\{[^}]*\})|(\S+))/gi;

const crepusImageSrcPattern =
  /\b(?:image|img)\b[^\n]*\bsrc=(\{[^}]+\}|[^\s]+)/gi;

export type CrepusValidation =
  | { ok: true; value: string }
  | { ok: false; error: string };

const decodeCrepusValue = (
  braced: string | undefined,
  bare: string | undefined,
) => {
  const raw = braced ?? bare ?? "";
  if (braced !== undefined) {
    const trimmed = raw.trim();
    if (trimmed.startsWith("{") && trimmed.endsWith("}"))
      return trimmed.slice(1, -1).trim();
    return trimmed;
  }
  if (raw.startsWith('"') && raw.endsWith('"')) {
    return raw
      .slice(1, -1)
      .replaceAll('\\"', '"')
      .replaceAll("\\\\", "\\")
      .trim();
  }
  return raw.trim();
};

export const isAllowedCrepusAction = (action: string): boolean => {
  if (action === "complete" || action === "accept") return true;
  const promptPrefix = "prompt:";
  if (action.startsWith(promptPrefix))
    return action.slice(promptPrefix.length).trim().length > 0;
  const computePrefix = "compute:";
  if (action.startsWith(computePrefix))
    return action.slice(computePrefix.length).trim().length > 0;
  const openPrefix = "open:";
  if (action.startsWith(openPrefix)) {
    try {
      const url = new URL(action.slice(openPrefix.length).trim());
      return (
        (url.protocol === "http:" || url.protocol === "https:") &&
        url.hostname.length > 0
      );
    } catch {
      return false;
    }
  }
  return false;
};

const isPrivateOrLocalHost = (hostname: string): boolean => {
  const host = hostname.toLowerCase().replace(/^\[/, "").replace(/\]$/, "");
  if (blockedImageHosts.has(host)) return true;
  if (host.endsWith(".local") || host.endsWith(".internal")) return true;
  if (host.includes(":")) {
    if (host === "::1" || host.startsWith("fc") || host.startsWith("fd"))
      return true;
    if (host.startsWith("fe80")) return true;
  }
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!ipv4) return false;
  const octets = ipv4.slice(1).map((part) => Number(part));
  if (octets.some((part) => part > 255)) return true;
  const [a, b] = octets;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 0) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
};

export const isSafeCrepusImageUrl = (url: string): boolean => {
  if (url.length === 0 || url.length > crepusImageUrlMaxLen) return false;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  if (parsed.username || parsed.password) return false;
  if (parsed.hostname.length === 0) return false;
  return !isPrivateOrLocalHost(parsed.hostname);
};

export const findDisallowedCrepusAction = (source: string): string | null => {
  for (const match of source.matchAll(crepusEventPattern)) {
    const action = decodeCrepusValue(match[2], match[3] ?? match[1]);
    if (action.length === 0 || isAllowedCrepusAction(action)) continue;
    return `Invalid crepus action: ${action}`;
  }
  return null;
};

export const findUnsafeCrepusImageUrl = (source: string): string | null => {
  for (const match of source.matchAll(crepusImageSrcPattern)) {
    const raw = match[1] ?? "";
    const url = decodeCrepusValue(
      raw.startsWith("{") ? raw.slice(1, -1) : undefined,
      raw.startsWith("{") ? undefined : raw,
    );
    if (isSafeCrepusImageUrl(url)) continue;
    return `Invalid crepus image URL: ${url || "<empty>"}`;
  }
  return null;
};

export const validateCrepus = (value: unknown): CrepusValidation => {
  if (typeof value !== "string")
    return { ok: false, error: "Invalid crepus: expected a string" };
  const trimmed = value.trim();
  if (trimmed.length === 0)
    return { ok: false, error: "Invalid crepus: must not be blank" };
  if (Array.from(trimmed).length > crepusMaxLen)
    return { ok: false, error: "Invalid crepus: exceeds maximum length" };
  const actionError = findDisallowedCrepusAction(trimmed);
  if (actionError) return { ok: false, error: actionError };
  const imageError = findUnsafeCrepusImageUrl(trimmed);
  if (imageError) return { ok: false, error: imageError };
  return { ok: true, value: trimmed };
};

export const sanitizeCrepus = (value: unknown): string | null => {
  const validated = validateCrepus(value);
  return validated.ok ? validated.value : null;
};
