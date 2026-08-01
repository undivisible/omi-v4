import Lenis from "lenis";
import * as THREE from "three";

const reduced = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function initLenis() {
  if (reduced()) return null;
  const lenis = new Lenis({
    autoRaf: true,
    smoothWheel: true,
    lerp: 0.09,
  });
  (window as unknown as { __omiLenis?: Lenis }).__omiLenis = lenis;
  return lenis;
}

function initHeroRotator(root: HTMLElement) {
  const words = root.querySelectorAll<HTMLElement>("[data-hero-word]");
  if (words.length < 2) return;
  let i = 0;
  words.forEach((el, idx) => el.classList.toggle("is-active", idx === 0));
  if (reduced()) return;
  window.setInterval(() => {
    words[i]?.classList.remove("is-active");
    i = (i + 1) % words.length;
    words[i]?.classList.add("is-active");
    const progress = root.querySelector<HTMLElement>("[data-hero-progress]");
    if (progress) progress.style.width = `${((i + 1) / words.length) * 100}%`;
  }, 2800);
}

function initManifesto(root: HTMLElement) {
  const manifesto = root.querySelector<HTMLElement>("#manifesto");
  if (!manifesto) return;
  const onScroll = () => {
    const rect = manifesto.getBoundingClientRect();
    const vh = window.innerHeight;
    const progress = Math.min(
      1,
      Math.max(0, 1 - (rect.bottom - vh * 0.2) / (rect.height + vh * 0.4)),
    );
    const blur = (1 - progress) * 12;
    manifesto.style.setProperty("--manifesto-blur", `${blur.toFixed(2)}px`);
    manifesto.style.setProperty("--manifesto-opacity", `${(0.35 + progress * 0.65).toFixed(3)}`);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });
}

function makeHelix(
  color: string,
  phase: number,
  turns = 4,
  points = 220,
): THREE.Points {
  const positions = new Float32Array(points * 3);
  const radius = 1.15;
  for (let i = 0; i < points; i++) {
    const t = i / (points - 1);
    const angle = t * Math.PI * 2 * turns + phase;
    positions[i * 3] = Math.cos(angle) * radius;
    positions[i * 3 + 1] = (t - 0.5) * 4.2;
    positions[i * 3 + 2] = Math.sin(angle) * radius;
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  const mat = new THREE.PointsMaterial({
    color,
    size: 0.045,
    transparent: true,
    opacity: 0.85,
    depthWrite: false,
    sizeAttenuation: true,
  });
  return new THREE.Points(geo, mat);
}

function initUnifies(root: HTMLElement) {
  const section = root.querySelector<HTMLElement>("#omi-unifies");
  const canvasHost = root.querySelector<HTMLElement>("[data-unifies-canvas]");
  const title = root.querySelector<HTMLElement>("[data-unifies-title]");
  if (!section || !canvasHost) return;

  if (reduced()) {
    canvasHost.dataset.fallback = "1";
    return;
  }

  const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  canvasHost.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 40);
  camera.position.set(0, 0, 6.2);

  const group = new THREE.Group();
  group.add(makeHelix("#fffcec", 0));
  group.add(makeHelix("#9aa0ff", Math.PI));
  scene.add(group);

  const amb = new THREE.AmbientLight(0xffffff, 0.8);
  scene.add(amb);

  const resize = () => {
    const { clientWidth: w, clientHeight: h } = canvasHost;
    renderer.setSize(w, h, false);
    camera.aspect = w / Math.max(h, 1);
    camera.updateProjectionMatrix();
  };
  resize();
  window.addEventListener("resize", resize);

  let raf = 0;
  const tick = (t: number) => {
    const rect = section.getBoundingClientRect();
    const total = section.offsetHeight - window.innerHeight;
    const scrolled = Math.min(1, Math.max(0, -rect.top / Math.max(total, 1)));
    group.rotation.y = scrolled * Math.PI * 2 + t * 0.00015;
    group.rotation.x = Math.sin(scrolled * Math.PI) * 0.25;
    group.position.y = (scrolled - 0.5) * 0.4;
    if (title) {
      title.style.opacity = String(0.25 + scrolled * 0.75);
      title.style.transform = `scale(${(0.92 + scrolled * 0.08).toFixed(3)})`;
    }
    renderer.render(scene, camera);
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);

  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting && raf) {
          cancelAnimationFrame(raf);
          raf = 0;
        } else if (e.isIntersecting && !raf) {
          raf = requestAnimationFrame(tick);
        }
      }
    },
    { rootMargin: "20% 0px" },
  );
  io.observe(section);
}

function initStepsStack(root: HTMLElement) {
  const stack = root.querySelector<HTMLElement>(".steps-stack");
  if (!stack) return;
  const cards = [...stack.querySelectorAll<HTMLElement>(".step-card")];
  if (!cards.length) return;

  const onScroll = () => {
    const rect = stack.getBoundingClientRect();
    const vh = window.innerHeight;
    cards.forEach((card, i) => {
      const start = i / cards.length;
      const local =
        (vh * 0.55 - rect.top) / Math.max(rect.height - vh * 0.2, 1);
      const focus = 1 - Math.min(1, Math.abs(local - (start + 0.5 / cards.length)) * 3);
      const blur = (1 - Math.max(0, focus)) * 10;
      card.style.setProperty("--step-blur", `${blur.toFixed(2)}px`);
      card.style.setProperty("--step-scale", `${(0.94 + focus * 0.06).toFixed(3)}`);
      card.style.setProperty("--step-opacity", `${(0.45 + focus * 0.55).toFixed(3)}`);
    });
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });
}

function initQueryMarquee(root: HTMLElement) {
  const track = root.querySelector<HTMLElement>("[data-query-track]");
  if (!track || reduced()) return;
  let x = 0;
  const step = () => {
    x -= 0.35;
    const width = track.scrollWidth / 2;
    if (Math.abs(x) >= width) x = 0;
    track.style.transform = `translate3d(${x}px,0,0)`;
    requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

function boot() {
  const root = document.querySelector<HTMLElement>("[data-computer-stage]");
  if (!root) return;
  initLenis();
  initHeroRotator(root);
  initManifesto(root);
  initUnifies(root);
  initStepsStack(root);
  initQueryMarquee(root);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
