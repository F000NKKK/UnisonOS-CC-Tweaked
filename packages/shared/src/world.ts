export const DEFAULT_WORLD = "default";

export function sanitiseWorldId(raw: string | null | undefined): string {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return DEFAULT_WORLD;
  const cleaned = trimmed
    .split("")
    .filter((c) => /[A-Za-z0-9_\-.]/.test(c))
    .join("");
  return cleaned || DEFAULT_WORLD;
}
