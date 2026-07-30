// The demo's model bridge. Loaded from the same origin as /hub/ and nothing
// else: this file uses the browser's Prompt API only.
(() => {
  const PROMPT_OPTIONS = {
    expectedInputs: [{ type: "text", languages: ["en"] }],
    expectedOutputs: [{ type: "text", languages: ["en"] }],
  };

  let promptSession = null;
  let promptSystem = "";
  let promptAbort = null;
  let cancelled = false;
  let lastProbe = "";
  let lastPrepare = "";

  const hasPromptApi = () => typeof globalThis.LanguageModel !== "undefined";

  const languageModel = () => globalThis.LanguageModel;

  async function probePromptApi() {
    if (!hasPromptApi()) return "unsupported";
    try {
      const api = languageModel();
      let state;
      try {
        state = await api.availability(PROMPT_OPTIONS);
      } catch (_) {
        state = await api.availability();
      }
      if (state === "unavailable" || state === "no") return "unsupported";
      return state === "available" || state === "readily"
        ? "ready"
        : "downloadable";
    } catch (_) {
      return "unsupported";
    }
  }

  async function probe() {
    let promptApi = "unsupported";
    try {
      promptApi = await probePromptApi();
    } catch (_) {}
    lastProbe = JSON.stringify({ promptApi });
    return lastProbe;
  }

  function promptMonitor(onProgress) {
    return (monitor) => {
      monitor.addEventListener("downloadprogress", (event) => {
        if (typeof onProgress === "function") {
          onProgress(Math.round((event.loaded / event.total) * 100));
        }
      });
    };
  }

  async function preparePromptApi(system = "", onProgress = null) {
    if (promptSession && promptSystem === system) return;
    try {
      promptSession?.destroy?.();
    } catch (_) {}
    promptAbort?.abort();
    promptAbort = null;
    const initialPrompts = system
      ? [{ role: "system", content: system }]
      : [];
    const options = {
      ...PROMPT_OPTIONS,
      initialPrompts,
      monitor: promptMonitor(onProgress),
    };
    try {
      promptSession = await languageModel().create(options);
    } catch (_) {
      promptSession = await languageModel().create({
        initialPrompts,
        monitor: promptMonitor(onProgress),
      });
    }
    promptSystem = system;
  }

  async function prepare(tier, onProgress) {
    lastPrepare = "";
    try {
      if (tier !== "prompt-api") {
        lastPrepare = "unsupported";
      } else {
        await preparePromptApi("", onProgress);
        lastPrepare = "ready";
      }
    } catch (error) {
      lastPrepare = `failed: ${error && error.message ? error.message : error}`;
    }
    return lastPrepare;
  }

  function messages(payload) {
    const turns = [];
    for (const turn of payload.history || []) {
      turns.push({ role: turn.role, content: turn.text });
    }
    turns.push({ role: "user", content: payload.prompt });
    return turns;
  }

  async function askPromptApi(payload, onChunk) {
    await preparePromptApi(payload.system);
    promptAbort = new AbortController();
    const turns = messages(payload);
    const prompt = turns.length === 1 ? payload.prompt : turns;
    const stream = promptSession.promptStreaming(prompt, {
      signal: promptAbort.signal,
    });
    let seen = "";
    for await (const piece of stream) {
      if (cancelled) return;
      const delta = piece.startsWith(seen) ? piece.slice(seen.length) : piece;
      seen = piece.startsWith(seen) ? piece : seen + piece;
      if (delta) onChunk(delta);
    }
  }

  async function ask(tier, payloadJson, onChunk, onDone, onError) {
    cancelled = false;
    try {
      if (tier !== "prompt-api") throw new Error(`unknown tier ${tier}`);
      await askPromptApi(JSON.parse(payloadJson), onChunk);
      onDone();
    } catch (error) {
      onError(String(error && error.message ? error.message : error));
    }
  }

  function cancel() {
    cancelled = true;
    promptAbort?.abort();
  }

  function reset() {
    cancel();
    try {
      promptSession?.destroy?.();
    } catch (_) {}
    promptSession = null;
    promptSystem = "";
    promptAbort = null;
    cancelled = false;
  }

  function startAsk(tier, payloadJson, onChunk, onDone, onError) {
    void ask(tier, payloadJson, onChunk, onDone, onError);
  }

  globalThis.omiDemoLlm = {
    probe,
    prepare,
    startAsk,
    cancel,
    reset,
    get last() {
      return lastProbe;
    },
    get lastPrepare() {
      return lastPrepare;
    },
  };

  void probe();
})();
