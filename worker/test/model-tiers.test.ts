import { describe, expect, test } from "bun:test";
import {
  ModelCapabilityError,
  asyncAudioTierPreference,
  capabilitiesOf,
  modelForCapability,
  modelForTier,
  modelSupports,
  selectModelFor,
} from "../src/model-tiers";
import type { Bindings } from "../src/types";

const environment = (overrides: Partial<Bindings> = {}) =>
  overrides as unknown as Bindings;

describe("model capabilities", () => {
  test("the audio tiers declare audio and the text tiers do not", () => {
    const env = environment();
    expect(capabilitiesOf(env, modelForTier(env, "balanced"))).toContain(
      "audioIn",
    );
    expect(capabilitiesOf(env, modelForTier(env, "transcribe"))).toContain(
      "audioIn",
    );
    expect(capabilitiesOf(env, modelForTier(env, "multimodal"))).toContain(
      "imageIn",
    );
    expect(capabilitiesOf(env, modelForTier(env, "speak"))).toContain(
      "audioOut",
    );
    expect(modelSupports(env, modelForTier(env, "speed"), ["audioIn"])).toBe(
      false,
    );
    expect(modelSupports(env, modelForTier(env, "smart"), ["audioIn"])).toBe(
      false,
    );
    expect(modelSupports(env, modelForTier(env, "search"), ["audioIn"])).toBe(
      false,
    );
  });

  test("no model claims realtime, which belongs to Gemini Live", () => {
    const env = environment();
    expect(() =>
      selectModelFor(env, ["realtime"], ["balanced", "speed"]),
    ).toThrow(ModelCapabilityError);
  });

  test("an unverified model satisfies nothing until it declares itself", () => {
    const env = environment({ OMI_MODEL_TRANSCRIBE: "some/unknown-model" });
    expect(() => modelForCapability(env, "transcribe", ["audioIn"])).toThrow(
      ModelCapabilityError,
    );
    const declared = environment({
      OMI_MODEL_TRANSCRIBE: "some/unknown-model",
      OMI_MODEL_CAPABILITIES: JSON.stringify({
        "some/unknown-model": ["text", "audioIn"],
      }),
    });
    expect(modelForCapability(declared, "transcribe", ["audioIn"])).toBe(
      "some/unknown-model",
    );
  });

  test("an override that cannot carry the request is refused", () => {
    const env = environment({
      OMI_MODEL_SPEAK: "inception/mercury-2",
    });
    expect(() => modelForCapability(env, "speak", ["audioOut"])).toThrow(
      ModelCapabilityError,
    );
  });

  test("a malformed capability declaration declares nothing", () => {
    const env = environment({
      OMI_MODEL_TRANSCRIBE: "some/unknown-model",
      OMI_MODEL_CAPABILITIES: "{not json",
    });
    expect(() => modelForCapability(env, "transcribe", ["audioIn"])).toThrow(
      ModelCapabilityError,
    );
  });

  test("asynchronous audio picks the balanced model", () => {
    const env = environment();
    expect(selectModelFor(env, ["audioIn"], asyncAudioTierPreference)).toEqual({
      tier: "balanced",
      model: "xiaomi/mimo-v2.5",
    });
  });

  test("selection walks past a tier that lost the capability", () => {
    const env = environment({ OMI_MODEL_BALANCED: "inception/mercury-2" });
    expect(
      selectModelFor(env, ["audioIn"], asyncAudioTierPreference).tier,
    ).toBe("transcribe");
  });

  test("selection fails loudly when no preferred tier qualifies", () => {
    const env = environment({
      OMI_MODEL_BALANCED: "inception/mercury-2",
      OMI_MODEL_TRANSCRIBE: "inception/mercury-2",
      OMI_MODEL_MULTIMODAL: "inception/mercury-2",
    });
    let raised: unknown = null;
    try {
      selectModelFor(env, ["audioIn"], asyncAudioTierPreference);
    } catch (error) {
      raised = error;
    }
    expect(raised).toBeInstanceOf(ModelCapabilityError);
    expect((raised as ModelCapabilityError).missing).toEqual(["audioIn"]);
  });
});
