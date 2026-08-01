import Lenis from "lenis";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

gsap.registerPlugin(ScrollTrigger);

const reduced = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

/** Noise-edge dissolve (Computer-style desplatter), no Three.js. */
function initDissolve(root: HTMLElement) {
  const section = root.querySelector<HTMLElement>("#omi-unifies");
  const host = root.querySelector<HTMLElement>("[data-dissolve-canvas]");
  const copy = root.querySelector<HTMLElement>("[data-dissolve-copy]");
  if (!section || !host) return;

  if (reduced()) {
    host.dataset.fallback = "1";
    if (copy) copy.style.opacity = "1";
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

  const vs = `#version 300 es
in vec2 a_pos;
out vec2 v_uv;
void main() {
  v_uv = a_pos * 0.5 + 0.5;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}`;

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
  float n = fbm(p * 3.4 + u_time * 0.04);
  float edge = u_edge;
  float burn = smoothstep(u_progress - edge, u_progress + edge, n);
  float rim = smoothstep(u_progress - edge * 1.4, u_progress, n)
    * (1.0 - smoothstep(u_progress, u_progress + edge * 1.2, n));
  vec3 veil = vec3(0.98, 0.97, 0.93);
  vec3 ember = vec3(0.62, 0.40, 0.33);
  vec3 col = mix(veil, ember, rim * 0.85);
  float alpha = burn * 0.97 + rim * 0.35;
  outColor = vec4(col, alpha);
}`;

  const compile = (type: number, src: string) => {
    const sh = gl.createShader(type)!;
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(sh) ?? "shader");
    }
    return sh;
  };

  const prog = gl.createProgram()!;
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, vs));
  gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(prog) ?? "link");
  }
  gl.useProgram(prog);

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

  const uProgress = gl.getUniformLocation(prog, "u_progress");
  const uTime = gl.getUniformLocation(prog, "u_time");
  const uEdge = gl.getUniformLocation(prog, "u_edge");
  const uRes = gl.getUniformLocation(prog, "u_res");

  let progress = 0;
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
    gl.uniform1f(uProgress, progress);
    gl.uniform1f(uTime, t * 0.001);
    gl.uniform1f(uEdge, 0.2);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  };

  gsap.ticker.add(draw);

  ScrollTrigger.create({
    trigger: section,
    start: "top top",
    end: "bottom bottom",
    scrub: 0.45,
    onUpdate: (self) => {
      progress = self.progress;
      if (copy) {
        const reveal = Math.min(1, Math.max(0, (self.progress - 0.15) / 0.55));
        copy.style.opacity = String(reveal);
        copy.style.filter = `blur(${((1 - reveal) * 10).toFixed(2)}px)`;
        copy.style.transform = `scale(${(0.96 + reveal * 0.04).toFixed(3)})`;
      }
    },
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
