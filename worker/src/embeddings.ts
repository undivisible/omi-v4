import type { Bindings } from "./types";

export const embeddingModel = "@cf/baai/bge-base-en-v1.5";
export const embeddingDimensions = 768;
const maximumInputCharacters = 2_000;

type EmbeddingResult = { data?: unknown };

export const embedTexts = async (
  env: Bindings,
  texts: string[],
): Promise<number[][] | null> => {
  if (texts.length === 0) return [];
  if (!env.AI) return null;
  try {
    const result = (await env.AI.run(embeddingModel, {
      text: texts.map((value) => value.slice(0, maximumInputCharacters)),
    })) as EmbeddingResult;
    const vectors = result?.data;
    return Array.isArray(vectors) &&
      vectors.length === texts.length &&
      vectors.every(
        (vector) =>
          Array.isArray(vector) &&
          vector.length > 0 &&
          vector.every((value) => typeof value === "number"),
      )
      ? (vectors as number[][])
      : null;
  } catch {
    return null;
  }
};
