import Lenis from "lenis";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

gsap.registerPlugin(ScrollTrigger);

const reduced = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function compileShader(
  gl: WebGL2RenderingContext,
  type: number,
  src: string,
): WebGLShader {
  const sh = gl.createShader(type)!;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) ?? "shader");
  }
  return sh;
}

function makeProgram(
  gl: WebGL2RenderingContext,
  vsSrc: string,
  fsSrc: string,
): WebGLProgram {
  const prog = gl.createProgram()!;
  gl.attachShader(prog, compileShader(gl, gl.VERTEX_SHADER, vsSrc));
  gl.attachShader(prog, compileShader(gl, gl.FRAGMENT_SHADER, fsSrc));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(prog) ?? "link");
  }
  return prog;
}

const FULLSCREEN_VS = `#version 300 es
in vec2 a_pos;
out vec2 v_uv;
void main() {
  v_uv = a_pos * 0.5 + 0.5;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}`;

function bindFullscreenQuad(gl: WebGL2RenderingContext, prog: WebGLProgram) {
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(
    gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]),
    gl.STATIC_DRAW,
  );
  const loc = gl.getAttribLocation(prog, "a_pos");
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
}

function initLenis() {
  if (reduced()) return null;
  const lenis = new Lenis({
    autoRaf: false,
    smoothWheel: true,
    lerp: 0.085,
  });
  lenis.on("scroll", ScrollTrigger.update);
  gsap.ticker.add((time) => {
    lenis.raf(time * 1000);
  });
  gsap.ticker.lagSmoothing(0);
  (window as unknown as { __omiLenis?: Lenis }).__omiLenis = lenis;
  return lenis;
}

function initHero() {
  const hero = document.querySelector<HTMLElement>("[data-hero]");
  if (!hero || reduced()) return;

  const tl = gsap.timeline({ defaults: { ease: "power3.out" } });
  tl.fromTo(
    hero.querySelectorAll("[data-hero-in]"),
    { y: 36, opacity: 0 },
    { y: 0, opacity: 1, duration: 0.9, stagger: 0.08 },
  );

  const media = hero.querySelector<HTMLElement>("[data-hero-media]");
  if (media) {
    gsap.fromTo(
      media,
      { scale: 1.08, opacity: 0.4 },
      {
        scale: 1,
        opacity: 1,
        duration: 1.4,
        ease: "power2.out",
      },
    );
    gsap.to(media, {
      yPercent: 12,
      ease: "none",
      scrollTrigger: {
        trigger: hero,
        start: "top top",
        end: "bottom top",
        scrub: true,
      },
    });
  }
}

/** Example Omi replies float upward until the desplatter section. */
function initFloatReplies(root: HTMLElement) {
  const layer = root.querySelector<HTMLElement>("[data-float-replies]");
  const dissolve = root.querySelector<HTMLElement>("#omi-unifies");
  if (!layer || !dissolve) return;
  const cards = [...layer.querySelectorAll<HTMLElement>("[data-float-card]")];
  if (!cards.length) return;

  if (reduced()) {
    layer.style.opacity = "0.55";
    return;
  }

  cards.forEach((card, i) => {
    const x = (i % 2 === 0 ? -1 : 1) * (18 + (i % 3) * 10);
    gsap.set(card, {
      xPercent: x,
      y: 40 + i * 28,
      opacity: 0,
      rotate: i % 2 === 0 ? -2 : 2,
    });
    gsap.to(card, {
      opacity: 0.92,
      duration: 0.8,
      delay: 0.35 + i * 0.12,
      ease: "power2.out",
    });
    gsap.to(card, {
      y: "-=120",
      duration: 14 + i * 1.4,
      repeat: -1,
      ease: "none",
      delay: i * 0.4,
    });
    gsap.to(card, {
      x: `+=${i % 2 === 0 ? 18 : -18}`,
      duration: 5 + (i % 3),
      yoyo: true,
      repeat: -1,
      ease: "sine.inOut",
      delay: i * 0.2,
    });
  });

  gsap.to(layer, {
    opacity: 0,
    y: -40,
    ease: "none",
    scrollTrigger: {
      trigger: dissolve,
      start: "top 20%",
      end: "top top",
      scrub: true,
    },
  });
}

/** Soft 8-dot field behind the manifesto copy. */
function initThreadShader(root: HTMLElement) {
  const host = root.querySelector<HTMLElement>("[data-thread-shader]");
  if (!host) return;
  if (reduced()) {
    host.dataset.fallback = "1";
    return;
  }

  const canvas = document.createElement("canvas");
  host.appendChild(canvas);
  const gl = canvas.getContext("webgl2", {
    alpha: true,
    antialias: true,
    premultipliedAlpha: false,
  });
  if (!gl) {
    host.dataset.fallback = "1";
    return;
  }

  const fs = `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 outColor;
uniform float u_time;
uniform vec2 u_res;

float circle(vec2 p, float r) {
  return smoothstep(r, r - 0.01, length(p));
}

void main() {
  vec2 uv = v_uv;
  float aspect = u_res.x / max(u_res.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);

  float pulse = 0.5 + 0.5 * sin(u_time * 0.7);
  float radius = 0.28 + pulse * 0.02;
  float glow = 0.0;
  vec3 accent = vec3(0.62, 0.40, 0.33);
  vec3 cream = vec3(0.98, 0.97, 0.93);

  for (int i = 0; i < 8; i++) {
    float a = float(i) * 6.2831853 / 8.0 + u_time * 0.08;
    vec2 c = vec2(cos(a), sin(a)) * radius;
    float d = length(p - c);
    float dot = smoothstep(0.055, 0.0, d);
    float halo = exp(-d * 14.0) * (0.35 + 0.25 * sin(u_time * 1.4 + float(i)));
    glow += dot * 0.9 + halo;
  }

  float ring = abs(length(p) - radius);
  float ringGlow = exp(-ring * 28.0) * 0.22;
  float mist = exp(-length(p) * 2.2) * 0.18;

  vec3 col = mix(vec3(0.08, 0.07, 0.06), accent, mist);
  col = mix(col, cream, clamp(glow * 0.55, 0.0, 1.0));
  col += accent * ringGlow;

  float alpha = clamp(mist * 1.4 + glow * 0.65 + ringGlow, 0.0, 0.85);
  outColor = vec4(col, alpha);
}`;

  const prog = makeProgram(gl, FULLSCREEN_VS, fs);
  gl.useProgram(prog);
  bindFullscreenQuad(gl, prog);
  const uTime = gl.getUniformLocation(prog, "u_time");
  const uRes = gl.getUniformLocation(prog, "u_res");

  const resize = () => {
    const dpr = Math.min(window.devicePixelRatio, 2);
    const w = host.clientWidth;
    const h = host.clientHeight;
    canvas.width = Math.max(1, Math.floor(w * dpr));
    canvas.height = Math.max(1, Math.floor(h * dpr));
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(uRes, canvas.width, canvas.height);
  };
  resize();
  window.addEventListener("resize", resize);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

  const draw = (t: number) => {
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform1f(uTime, t * 0.001);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  };
  gsap.ticker.add(draw);
}

/**
 * Pinned desplatter: hold on competitor traits, burn them away, then reveal Omi.
 * Progress stays at 0 until the section is pinned (top of viewport).
 */
function initDissolve(root: HTMLElement) {
  const section = root.querySelector<HTMLElement>("[data-dissolve-section]");
  const stage = root.querySelector<HTMLElement>(".ed-dissolve-stage");
  const host = root.querySelector<HTMLElement>("[data-dissolve-canvas]");
  const them = root.querySelector<HTMLElement>("[data-dissolve-them]");
  const us = root.querySelector<HTMLElement>("[data-dissolve-us]");
  const traits = [
    ...(them?.querySelectorAll<HTMLElement>("[data-dissolve-trait]") ?? []),
  ];
  if (!section || !stage || !host || !them || !us) return;

  gsap.set(us, { opacity: 0, filter: "blur(12px)", y: 24 });
  gsap.set(them, { opacity: 1, filter: "blur(0px)" });
  gsap.set(traits, { opacity: 1, y: 0 });

  if (reduced()) {
    host.dataset.fallback = "1";
    gsap.set(them, { opacity: 0 });
    gsap.set(us, { opacity: 1, filter: "none", y: 0 });
    return;
  }

  const canvas = document.createElement("canvas");
  host.appendChild(canvas);
  const gl = canvas.getContext("webgl2", {
    alpha: true,
    antialias: false,
    premultipliedAlpha: false,
  });
  if (!gl) {
    host.dataset.fallback = "1";
    return;
  }

  // burn=1 → opaque (covering "them" with cream/ember), burn→0 as progress rises
  // so the noise hole opens through the competitor layer.
  const fs = `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 outColor;
uniform float u_progress;
uniform float u_time;
uniform float u_edge;
uniform vec2 u_res;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p *= 2.02;
    a *= 0.5;
  }
  return v;
}
void main() {
  vec2 uv = v_uv;
  float aspect = u_res.x / max(u_res.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  float n = fbm(p * 3.6 + u_time * 0.05);
  float edge = u_edge;
  // Invert classic veil: start clear over "them", then burn a cream/ember sheet
  // across them as holes — reads as attributes desplattering apart.
  float scatter = smoothstep(u_progress - edge, u_progress + edge, n);
  float holes = 1.0 - scatter;
  float rim = smoothstep(u_progress - edge * 1.5, u_progress, n)
    * (1.0 - smoothstep(u_progress, u_progress + edge * 1.3, n));
  vec3 ash = vec3(0.96, 0.93, 0.88);
  vec3 ember = vec3(0.62, 0.40, 0.33);
  vec3 col = mix(ash, ember, rim);
  float alpha = holes * 0.92 + rim * 0.55;
  // Hold fully clear until burn phase starts (u_progress near 0).
  alpha *= smoothstep(0.02, 0.12, u_progress);
  outColor = vec4(col, alpha);
}`;

  const prog = makeProgram(gl, FULLSCREEN_VS, fs);
  gl.useProgram(prog);
  bindFullscreenQuad(gl, prog);

  const uProgress = gl.getUniformLocation(prog, "u_progress");
  const uTime = gl.getUniformLocation(prog, "u_time");
  const uEdge = gl.getUniformLocation(prog, "u_edge");
  const uRes = gl.getUniformLocation(prog, "u_res");

  let burn = 0;
  const resize = () => {
    const dpr = Math.min(window.devicePixelRatio, 2);
    const w = host.clientWidth;
    const h = host.clientHeight;
    canvas.width = Math.max(1, Math.floor(w * dpr));
    canvas.height = Math.max(1, Math.floor(h * dpr));
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(uRes, canvas.width, canvas.height);
  };
  resize();
  window.addEventListener("resize", resize);

  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

  const draw = (t: number) => {
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform1f(uProgress, burn);
    gl.uniform1f(uTime, t * 0.001);
    gl.uniform1f(uEdge, 0.18);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  };
  gsap.ticker.add(draw);

  const applyPhase = (p: number) => {
    // 0–0.18 hold on competitors (no burn)
    // 0.18–0.62 burn / scatter them
    // 0.48–1.0 reveal Omi
    const hold = 0.18;
    const burnEnd = 0.62;
    const burnT = Math.min(1, Math.max(0, (p - hold) / (burnEnd - hold)));
    burn = burnT;

    const themFade = 1 - Math.min(1, Math.max(0, (p - 0.28) / 0.34));
    them.style.opacity = String(themFade);
    them.style.filter = `blur(${((1 - themFade) * 8).toFixed(2)}px)`;
    them.style.transform = `scale(${(1 + (1 - themFade) * 0.03).toFixed(3)})`;

    traits.forEach((trait, i) => {
      const local = Math.min(
        1,
        Math.max(0, (burnT - i * 0.07) / 0.35),
      );
      trait.style.opacity = String(1 - local);
      trait.style.transform = `translateY(${(-12 * local).toFixed(1)}px) scale(${(1 - local * 0.06).toFixed(3)})`;
    });

    const usT = Math.min(1, Math.max(0, (p - 0.48) / 0.4));
    us.style.opacity = String(usT);
    us.style.filter = `blur(${((1 - usT) * 12).toFixed(2)}px)`;
    us.style.transform = `translateY(${(24 * (1 - usT)).toFixed(1)}px) scale(${(0.96 + usT * 0.04).toFixed(3)})`;
  };

  applyPhase(0);

  ScrollTrigger.create({
    trigger: section,
    start: "top top",
    end: "+=280%",
    pin: stage,
    scrub: 0.55,
    anticipatePin: 1,
    invalidateOnRefresh: true,
    onUpdate: (self) => applyPhase(self.progress),
  });
}

function initReveal(root: HTMLElement) {
  if (reduced()) {
    root.querySelectorAll("[data-reveal]").forEach((el) => {
      (el as HTMLElement).style.opacity = "1";
    });
    return;
  }

  root.querySelectorAll<HTMLElement>("[data-reveal]").forEach((el) => {
    gsap.fromTo(
      el,
      { y: 28, opacity: 0 },
      {
        y: 0,
        opacity: 1,
        duration: 0.85,
        ease: "power3.out",
        scrollTrigger: {
          trigger: el,
          start: "top 88%",
          toggleActions: "play none none reverse",
        },
      },
    );
  });

  root.querySelectorAll<HTMLElement>("[data-stagger]").forEach((group) => {
    const kids = group.querySelectorAll(":scope > *");
    gsap.fromTo(
      kids,
      { y: 22, opacity: 0 },
      {
        y: 0,
        opacity: 1,
        duration: 0.7,
        stagger: 0.07,
        ease: "power2.out",
        scrollTrigger: {
          trigger: group,
          start: "top 86%",
        },
      },
    );
  });
}

function initSteps(root: HTMLElement) {
  const cards = root.querySelectorAll<HTMLElement>("[data-step]");
  if (!cards.length || reduced()) return;
  cards.forEach((card) => {
    gsap.fromTo(
      card,
      { y: 40, opacity: 0.35, filter: "blur(6px)" },
      {
        y: 0,
        opacity: 1,
        filter: "blur(0px)",
        ease: "none",
        scrollTrigger: {
          trigger: card,
          start: "top 80%",
          end: "top 35%",
          scrub: true,
        },
      },
    );
  });
}

function initHardware(root: HTMLElement) {
  const stage = root.querySelector<HTMLElement>("[data-hw-stage]");
  if (!stage || reduced()) return;
  const img = stage.querySelector<HTMLElement>("[data-hw-photo]");
  const chips = stage.querySelectorAll<HTMLElement>("[data-hw-chip]");
  const orbit = stage.querySelector<HTMLElement>("[data-hw-orbit]");

  if (img) {
    gsap.fromTo(
      img,
      { scale: 0.92, rotate: -2 },
      {
        scale: 1,
        rotate: 0,
        ease: "none",
        scrollTrigger: {
          trigger: stage,
          start: "top 75%",
          end: "center center",
          scrub: true,
        },
      },
    );
  }

  if (orbit) {
    gsap.to(orbit, {
      rotate: 360,
      duration: 48,
      repeat: -1,
      ease: "none",
    });
  }

  chips.forEach((chip, i) => {
    gsap.fromTo(
      chip,
      { y: 24, opacity: 0, x: i % 2 === 0 ? -16 : 16 },
      {
        y: 0,
        opacity: 1,
        x: 0,
        duration: 0.7,
        delay: 0.05 * i,
        ease: "power3.out",
        scrollTrigger: {
          trigger: stage,
          start: "top 70%",
        },
      },
    );
  });
}

function boot() {
  const root = document.querySelector<HTMLElement>("[data-computer-stage]");
  if (!root) return;
  initLenis();
  initHero();
  initFloatReplies(root);
  initThreadShader(root);
  initDissolve(root);
  initReveal(root);
  initSteps(root);
  initHardware(root);
  ScrollTrigger.refresh();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
