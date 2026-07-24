// The demo's model bridge. Loaded from the same origin as /hub/ and nothing
// else: this file makes no request of its own until the visitor has clicked
// through an explicit opt-in that names the download size.
//
// Three tiers, in order of preference:
//
//   prompt-api  the browser's own on-device model (Chrome's LanguageModel).
//               Already on the machine, so there is nothing to download and
//               nothing to consent to beyond the browser's own gesture.
//   webgpu      transformers.js, vendored next to this file, running a small
//               instruct model on WebGPU. Opt-in only, and only offered when
//               the machine looks like it can take it.
//   scripted    no model at all. Handled in Dart, not here.
(() => {
  const VENDOR = "vendor/";
  const MODEL_ID = "HuggingFaceTB/SmolLM2-360M-Instruct";
  const MODEL_LABEL = "SmolLM2 360M Instruct";
  // The weights plus the ONNX runtime wasm this origin serves alongside them.
  const MODEL_MB = 330;

  let promptSession = null;
  let generator = null;
  let cancelled = false;
  // The last probe and prepare results. They are read back as plain string
  // properties rather than as promise values: a promise that resolves to a
  // bare JS string is the one shape the Dart side cannot reliably unwrap.
  let lastProbe = "";
  let lastPrepare = "";

  const hasPromptApi = () =>
    typeof globalThis.LanguageModel !== "undefined" ||
    (globalThis.ai && typeof globalThis.ai.languageModel !== "undefined");

  const languageModel = () =>
    globalThis.LanguageModel || (globalThis.ai && globalThis.ai.languageModel);

  async function probePromptApi() {
    if (!hasPromptApi()) return "unsupported";
    try {
      const api = languageModel();
      const state = api.availability
        ? await api.availability()
        : (await api.capabilities()).available;
      if (state === "unavailable" || state === "no") return "unsupported";
      return state === "available" || state === "readily"
        ? "ready"
        : "downloadable";
    } catch (_) {
      return "unsupported";
    }
  }

  // A one-byte ranged read rather than a HEAD: some servers and some
  // extensions abort HEAD requests, and a probe that throws must not be able
  // to take the whole capability check down with it.
  async function vendorPresent() {
    try {
      const response = await fetch(`${VENDOR}transformers.js`, {
        headers: { Range: "bytes=0-0" },
      });
      return response.ok;
    } catch (_) {
      return false;
    }
  }

  // Deliberately conservative. A marketing page that starts a 300 MB download
  // on a laptop that cannot run the result is worse than no model at all, so
  // the tier is only ever offered when every signal agrees.
  function machineLooksCapable() {
    if (!navigator.gpu) return false;
    const memory = navigator.deviceMemory;
    if (typeof memory === "number" && memory < 8) return false;
    const cores = navigator.hardwareConcurrency;
    if (typeof cores === "number" && cores < 4) return false;
    return true;
  }

  async function probe() {
    let promptApi = "unsupported";
    let capable = false;
    let vendored = false;
    try {
      promptApi = await probePromptApi();
      capable = machineLooksCapable();
      vendored = capable ? await vendorPresent() : false;
    } catch (_) {
      // A capability probe that throws is a capability that is not there.
    }
    lastProbe = JSON.stringify({
      promptApi,
      webgpu: vendored && capable,
      model: MODEL_LABEL,
      downloadMb: MODEL_MB,
      deviceMemory: navigator.deviceMemory ?? null,
      cores: navigator.hardwareConcurrency ?? null,
    });
    return lastProbe;
  }

  async function preparePromptApi() {
    if (promptSession) return;
    promptSession = await languageModel().create();
  }

  async function prepareWebgpu(onProgress) {
    if (generator) return;
    const { pipeline, env } = await import(`./${VENDOR}transformers.js`);
    // Everything the runtime itself needs is served from this origin. Only
    // the model weights come from the hub, and only after the opt-in.
    // An absolute URL, not a relative one: the runtime resolves this as a
    // module specifier, which a bare relative path is not.
    env.backends.onnx.wasm.wasmPaths = new URL(VENDOR, location.href).href;
    env.allowLocalModels = false;
    generator = await pipeline("text-generation", MODEL_ID, {
      device: "webgpu",
      dtype: "q4f16",
      progress_callback: (report) => {
        if (typeof onProgress !== "function") return;
        const total = report.total || 0;
        const loaded = report.loaded || 0;
        const percent = total > 0 ? Math.round((loaded / total) * 100) : 0;
        onProgress(report.status === "ready" ? 100 : percent);
      },
    });
  }

  async function prepare(tier, onProgress) {
    lastPrepare = "";
    try {
      if (tier === "prompt-api") await preparePromptApi();
      else if (tier === "webgpu") await prepareWebgpu(onProgress);
      else lastPrepare = "unsupported";
      lastPrepare = lastPrepare || "ready";
    } catch (error) {
      lastPrepare = `failed: ${error && error.message ? error.message : error}`;
    }
    return lastPrepare;
  }

  function messages(payload) {
    const turns = [{ role: "system", content: payload.system }];
    for (const turn of payload.history || []) {
      turns.push({ role: turn.role, content: turn.text });
    }
    turns.push({ role: "user", content: payload.prompt });
    return turns;
  }

  async function askPromptApi(payload, onChunk) {
    await preparePromptApi();
    const prompt = messages(payload)
      .map((turn) => `${turn.role}: ${turn.content}`)
      .join("\n\n");
    const stream = promptSession.promptStreaming(prompt);
    let seen = "";
    for await (const piece of stream) {
      if (cancelled) return;
      // Older builds stream the whole answer so far rather than a delta.
      const delta = piece.startsWith(seen) ? piece.slice(seen.length) : piece;
      seen = piece.startsWith(seen) ? piece : seen + piece;
      if (delta) onChunk(delta);
    }
  }

  async function askWebgpu(payload, onChunk) {
    await prepareWebgpu(null);
    const { TextStreamer } = await import(`./${VENDOR}transformers.js`);
    const streamer = new TextStreamer(generator.tokenizer, {
      skip_prompt: true,
      skip_special_tokens: true,
      callback_function: (text) => {
        if (!cancelled && text) onChunk(text);
      },
    });
    await generator(messages(payload), {
      max_new_tokens: 220,
      temperature: 0.4,
      do_sample: true,
      streamer,
    });
  }

  async function ask(tier, payloadJson, onChunk, onDone, onError) {
    cancelled = false;
    try {
      const payload = JSON.parse(payloadJson);
      if (tier === "prompt-api") await askPromptApi(payload, onChunk);
      else if (tier === "webgpu") await askWebgpu(payload, onChunk);
      else throw new Error(`unknown tier ${tier}`);
      onDone();
    } catch (error) {
      onError(String(error && error.message ? error.message : error));
    }
  }

  function cancel() {
    cancelled = true;
  }

  // `startAsk` is the fire-and-forget form: the Dart side takes its result
  // through the callbacks rather than through the returned promise.
  function startAsk(tier, payloadJson, onChunk, onDone, onError) {
    void ask(tier, payloadJson, onChunk, onDone, onError);
  }

  globalThis.omiDemoLlm = {
    probe,
    prepare,
    startAsk,
    ask,
    cancel,
    get last() {
      return lastProbe;
    },
    get lastPrepare() {
      return lastPrepare;
    },
  };
})();
