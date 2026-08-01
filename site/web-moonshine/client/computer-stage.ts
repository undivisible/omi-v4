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

  gsap
    .timeline({ defaults: { ease: "power3.out" } })
    .fromTo(
      hero.querySelectorAll("[data-hero-in]"),
      { y: 36, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.9, stagger: 0.08 },
    );

  const media = hero.querySelector<HTMLElement>("[data-hero-media]");
  if (media) {
    gsap.fromTo(
      media,
      { scale: 1.08, opacity: 0.35 },
      { scale: 1, opacity: 1, duration: 1.4, ease: "power2.out" },
    );
    gsap.to(media, {
      yPercent: 14,
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

function initFloatReplies(root: HTMLElement) {
  const layer = root.querySelector<HTMLElement>("[data-float-replies]");
  const dissolve = root.querySelector<HTMLElement>("[data-dissolve-section]");
  if (!layer || !dissolve) return;
  const cards = [...layer.querySelectorAll<HTMLElement>("[data-float-card]")];
  if (!cards.length) return;

  if (reduced()) {
    layer.style.opacity = "0.45";
    return;
  }

  // An endless upward stream: cards are distributed along one loop and
  // conveyor-belt through it, wrapping from the top back to the bottom.
  const H = layer.clientHeight || window.innerHeight;
  const range = H * 1.35;
  const wrapY = gsap.utils.wrap(-0.25 * H, range - 0.25 * H);

  cards.forEach((card, i) => {
    card.style.top = "0px";
    const startY = wrapY((i / cards.length) * range);
    gsap.set(card, {
      y: startY,
      xPercent: i % 2 === 0 ? -6 : 6,
      opacity: 0.92,
      rotate: i % 2 === 0 ? -1.5 : 1.5,
    });
    gsap.to(card, {
      y: `-=${range}`,
      duration: range / (48 + (i % 3) * 12),
      repeat: -1,
      ease: "none",
      modifiers: {
        y: (y: string) => `${wrapY(parseFloat(y)).toFixed(1)}px`,
      },
    });
    gsap.to(card, {
      x: `+=${i % 2 === 0 ? 20 : -20}`,
      duration: 5.5 + (i % 4),
      yoyo: true,
      repeat: -1,
      ease: "sine.inOut",
    });
  });

  gsap.to(layer, {
    opacity: 0,
    y: -48,
    ease: "none",
    scrollTrigger: {
      trigger: dissolve,
      start: "top 25%",
      end: "top top",
      scrub: true,
    },
  });
}

/**
 * Pinned sequence:
 * hold competitors → Paramount-style mark deconstruct + trait scatter →
 * mark reforms + Omi copy. Noise burn peaks mid-way and clears (never lands white).
 */
function initDissolve(root: HTMLElement) {
  const section = root.querySelector<HTMLElement>("[data-dissolve-section]");
  const stage = root.querySelector<HTMLElement>(".ed-dissolve-stage");
  const host = root.querySelector<HTMLElement>("[data-dissolve-canvas]");
  const them = root.querySelector<HTMLElement>("[data-dissolve-them]");
  const us = root.querySelector<HTMLElement>("[data-dissolve-us]");
  const mark = root.querySelector<HTMLElement>(".ed-cold-mark");
  const traits = [
    ...(them?.querySelectorAll<HTMLElement>("[data-dissolve-trait]") ?? []),
  ];
  if (!section || !stage || !them || !us) return;

  // The dots live everywhere while the usual assistants hold the stage —
  // scattered to their own random points across the room — then gather into
  // the ring as Omi arrives. Positions are in SVG user units, so screen
  // distances are divided by the mark's render scale.
  const circles = mark
    ? [...mark.querySelectorAll<SVGCircleElement>("circle")]
    : [];
  let scatterTargets: Array<{ x: number; y: number }> = [];
  const seedScatter = () => {
    if (!mark || !circles.length) return;
    const rect = mark.getBoundingClientRect();
    const scale = (rect.width || 160) / 260;
    const w = stage.clientWidth || window.innerWidth;
    const h = stage.clientHeight || window.innerHeight;
    scatterTargets = circles.map((_, i) => {
      const ang =
        (i / circles.length) * Math.PI * 2 + (Math.random() - 0.5) * 1.4;
      return {
        x: (Math.cos(ang) * (0.16 + Math.random() * 0.26) * w) / scale,
        y: (Math.sin(ang) * (0.2 + Math.random() * 0.3) * h) / scale,
      };
    });
  };
  seedScatter();
  window.addEventListener("resize", seedScatter);

  let gather = 0; // 0 = fully scattered, 1 = ring assembled
  const placeDots = (time: number) => {
    circles.forEach((c, i) => {
      const t = scatterTargets[i];
      if (!t) return;
      const away = 1 - gather;
      const wob = away * 10;
      const x = t.x * away + Math.sin(time * 0.7 + i * 2.1) * wob;
      const y = t.y * away + Math.cos(time * 0.55 + i * 1.3) * wob;
      c.style.translate = `${x.toFixed(1)}px ${y.toFixed(1)}px`;
      c.style.opacity = String(0.7 + 0.3 * gather);
    });
  };
  if (circles.length && !reduced()) {
    gsap.ticker.add((t) => placeDots(t));
  }

  // Room colour follows the desplatter: settled dark, ember-lit at the
  // height of the burn, then a calmer warm dark once Omi holds the stage.
  const lerpC = (a: number[], b: number[], t: number) =>
    a.map((v, i) => Math.round(v + (b[i] - v) * t));
  const ROOM = [43, 39, 34];
  const EMBER = [64, 44, 30];
  const SETTLED = [36, 33, 29];
  const paintRoom = (p: number) => {
    const up = Math.min(1, Math.max(0, (p - 0.16) / 0.3));
    const down = Math.min(1, Math.max(0, (p - 0.55) / 0.3));
    const mid = lerpC(ROOM, EMBER, up);
    const c = lerpC(mid, SETTLED, down);
    section.style.backgroundColor = `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
  };
  const wash = section.querySelector<HTMLElement>("[data-wash]");

  gsap.set(us, { opacity: 0, filter: "blur(6px)", y: 18 });
  gsap.set(them, { opacity: 1, filter: "blur(0px)" });
  gsap.set(traits, { opacity: 1, y: 0, scale: 1 });

  if (reduced()) {
    if (host) host.dataset.fallback = "1";
    gsap.set(them, { opacity: 0 });
    gsap.set(us, { opacity: 1, filter: "none", y: 0 });
    gather = 1;
    placeDots(0);
    return;
  }

  let burn = 0;
  let gl: WebGL2RenderingContext | null = null;

  if (host) {
    const canvas = document.createElement("canvas");
    host.appendChild(canvas);
    gl = canvas.getContext("webgl2", {
      alpha: true,
      antialias: false,
      premultipliedAlpha: false,
    });
    if (!gl) {
      host.dataset.fallback = "1";
    } else {
      // Fine ember grain that peaks mid-scroll then clears — never a white
      // end state, never full-frame clouds. Concentrated centrally and
      // broken by high-frequency sparkle so it reads as embers, not fog.
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
  vec2 drift = vec2(0.0, u_time * 0.045);
  float n = fbm(p * 8.5 + drift);
  float edge = u_edge;
  float scatter = smoothstep(u_progress - edge, u_progress + edge, n);
  float holes = 1.0 - scatter;
  float rim = smoothstep(u_progress - edge * 1.5, u_progress, n)
    * (1.0 - smoothstep(u_progress, u_progress + edge * 1.3, n));
  float grain = noise(p * 90.0 + vec2(0.0, u_time * 0.6));
  float sparkle = 0.45 + 0.55 * grain;
  float vign = 1.0 - smoothstep(0.5, 1.05, length(p));
  vec3 ash = vec3(0.83, 0.68, 0.53);
  vec3 ember = vec3(0.66, 0.37, 0.27);
  vec3 room = vec3(0.17, 0.15, 0.13);
  vec3 col = mix(room, mix(ash, ember, rim), 0.9);
  float envelope = smoothstep(0.06, 0.26, u_progress)
    * (1.0 - smoothstep(0.68, 0.94, u_progress));
  float alpha = (holes * 0.28 + rim * 0.55) * sparkle * vign * envelope;
  outColor = vec4(col, alpha);
}`;

      const prog = makeProgram(gl, FULLSCREEN_VS, fs);
      gl.useProgram(prog);
      bindFullscreenQuad(gl, prog);
      const uProgress = gl.getUniformLocation(prog, "u_progress");
      const uTime = gl.getUniformLocation(prog, "u_time");
      const uEdge = gl.getUniformLocation(prog, "u_edge");
      const uRes = gl.getUniformLocation(prog, "u_res");

      const resize = () => {
        const dpr = Math.min(window.devicePixelRatio, 2);
        const w = host.clientWidth;
        const h = host.clientHeight;
        canvas.width = Math.max(1, Math.floor(w * dpr));
        canvas.height = Math.max(1, Math.floor(h * dpr));
        canvas.style.width = `${w}px`;
        canvas.style.height = `${h}px`;
        gl!.viewport(0, 0, canvas.width, canvas.height);
        gl!.uniform2f(uRes, canvas.width, canvas.height);
      };
      resize();
      window.addEventListener("resize", resize);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

      gsap.ticker.add((t) => {
        if (!gl) return;
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform1f(uProgress, burn);
        gl.uniform1f(uTime, t * 0.001);
        gl.uniform1f(uEdge, 0.11);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      });
    }
  }

  const applyPhase = (p: number) => {
    // 0–0.16 hold competitors + assembled mark
    // 0.16–0.55 deconstruct mark + scatter traits + burn
    // 0.50–0.85 reform mark + reveal Omi
    // 0.85–1.0 settle (finished)
    const hold = 0.16;
    const mid = 0.55;
    const t = Math.min(1, Math.max(0, (p - hold) / (mid - hold)));
    burn = t;

    // Cold-open in reverse: the dots start everywhere and gather into the
    // ring as Omi takes the stage. Ease-out so the last few px settle softly.
    const reform = Math.min(1, Math.max(0, (p - 0.48) / 0.34));
    gather = 1 - Math.pow(1 - reform, 3);
    paintRoom(p);
    if (wash) wash.style.opacity = String(0.6 + 0.3 * reform);

    const themFade = 1 - Math.min(1, Math.max(0, (p - 0.22) / 0.38));
    them.style.opacity = String(themFade);
    them.style.filter = `blur(${((1 - themFade) * 5).toFixed(2)}px)`;
    them.style.transform = `scale(${(1 + (1 - themFade) * 0.04).toFixed(3)})`;

    traits.forEach((trait, i) => {
      const local = Math.min(1, Math.max(0, (t - i * 0.06) / 0.32));
      const angle = (i / traits.length) * Math.PI * 2;
      const dist = local * 48;
      trait.style.opacity = String(1 - local);
      trait.style.transform = `translate(${(Math.cos(angle) * dist).toFixed(1)}px, ${(Math.sin(angle) * dist - 8 * local).toFixed(1)}px) scale(${(1 - local * 0.12).toFixed(3)})`;
    });

    const usT = Math.min(1, Math.max(0, (p - 0.5) / 0.35));
    us.style.opacity = String(usT);
    us.style.filter = `blur(${((1 - usT) * 6).toFixed(2)}px)`;
    us.style.transform = `translateY(${(18 * (1 - usT)).toFixed(1)}px)`;

    if (p >= 0.98) {
      burn = 1;
      gather = 1;
      them.style.opacity = "0";
      us.style.opacity = "1";
      us.style.filter = "none";
      us.style.transform = "none";
    }
  };

  applyPhase(0);

  ScrollTrigger.create({
    trigger: section,
    start: "top top",
    end: "+=220%",
    pin: stage,
    scrub: 0.65,
    anticipatePin: 1,
    invalidateOnRefresh: true,
    pinSpacing: true,
    onUpdate: (self) => applyPhase(self.progress),
    onLeave: () => applyPhase(1),
    onEnterBack: () => applyPhase(0.99),
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
      { y: 32, opacity: 0 },
      {
        y: 0,
        opacity: 1,
        duration: 0.9,
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
      { y: 26, opacity: 0 },
      {
        y: 0,
        opacity: 1,
        duration: 0.75,
        stagger: 0.08,
        ease: "power2.out",
        scrollTrigger: {
          trigger: group,
          start: "top 86%",
        },
      },
    );
  });

  // Soft parallax on band washes so sections feel continuous.
  root.querySelectorAll<HTMLElement>("[data-wash]").forEach((wash) => {
    gsap.to(wash, {
      yPercent: 8,
      ease: "none",
      scrollTrigger: {
        trigger: wash.parentElement ?? wash,
        start: "top bottom",
        end: "bottom top",
        scrub: true,
      },
    });
  });
}

function initSteps(root: HTMLElement) {
  const cards = root.querySelectorAll<HTMLElement>("[data-step]");
  if (!cards.length || reduced()) return;
  cards.forEach((card) => {
    gsap.fromTo(
      card,
      { y: 30, opacity: 0.4, filter: "blur(3px)" },
      {
        y: 0,
        opacity: 1,
        filter: "blur(0px)",
        ease: "none",
        scrollTrigger: {
          trigger: card,
          start: "top 82%",
          end: "top 38%",
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
      { scale: 0.9, rotate: -3 },
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
      duration: 56,
      repeat: -1,
      ease: "none",
    });
    const orbitMark = orbit.querySelector<HTMLElement>("[data-omi-mark]");
    if (orbitMark) {
      gsap.to(orbitMark, {
        "--omi-spread": 18,
        duration: 2.8,
        yoyo: true,
        repeat: -1,
        ease: "sine.inOut",
      });
    }
  }

  chips.forEach((chip, i) => {
    gsap.fromTo(
      chip,
      { y: 28, opacity: 0, x: i % 2 === 0 ? -20 : 20 },
      {
        y: 0,
        opacity: 1,
        x: 0,
        duration: 0.75,
        delay: 0.06 * i,
        ease: "power3.out",
        scrollTrigger: { trigger: stage, start: "top 70%" },
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
  initDissolve(root);
  initReveal(root);
  initSteps(root);
  initHardware(root);
  requestAnimationFrame(() => ScrollTrigger.refresh());
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
