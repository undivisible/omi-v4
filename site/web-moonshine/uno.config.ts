import { defineConfig, presetWind3 } from "unocss";

export default defineConfig({
  presets: [presetWind3({ preflight: false })],
  theme: {
    colors: {
      ink: "var(--ink)",
      cream: "var(--cream)",
      muted: "var(--muted)",
      muted2: "var(--muted-2)",
      rule: "var(--rule)",
      sky: "var(--sky)",
      paper: "var(--paper)",
      room: "var(--ed-room)",
      onDark: "rgba(255, 250, 243, 0.72)",
      onDarkDim: "rgba(255, 250, 243, 0.45)",
      onDarkRule: "rgba(255, 250, 243, 0.12)",
      onDarkDot: "rgba(255, 250, 243, 0.28)",
    },
    fontFamily: {
      sans: "var(--font)",
      serif: "var(--serif)",
      mono: "var(--mono)",
      pixel: "var(--pixel)",
    },
    easing: {
      omi: "var(--ease)",
    },
  },
  shortcuts: {
    label:
      "font-pixel text-[10px] tracking-[0.2em] uppercase text-onDarkDim",
    "hairline-t": "border-t-1 border-t-solid border-t-onDarkRule",
  },
});
