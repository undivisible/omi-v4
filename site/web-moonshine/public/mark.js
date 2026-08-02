/* The Omi mark's motion. Additive: it only touches [data-omi-mark] elements
   and reads hover on the primary call to action. If this file never loads,
   the mark still renders as the correct static ring.

   Reduced motion is handled twice over — the stylesheet removes every
   animation and transition, and this module returns before starting
   anything, so nothing schedules frames either. */
(() => {
  // The rail's mark is turned by scroll progress alone, in main.js, so it is
  // left out of the ambient drift below — two writers on one --omi-rot would
  // fight. It still takes the scatter and the pulse with everything else.
  const marks = [...document.querySelectorAll("[data-omi-mark]")];
  // Scroll-driven Paramount cold-open mark is owned by computer-stage.js.
  const ambient = marks.filter((mark) => !mark.matches(".ed-cold-mark"));
  const drifting = ambient.filter((mark) => !mark.matches(".omi-mark--rail"));
  if (!marks.length) return;

  const quiet = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (quiet.matches) return;

  // The ring arrives scattered and re-forms, one dot after the next. The
  // stagger lives in CSS transition-delay; all this does is release it.
  for (const mark of ambient) mark.style.setProperty("--omi-spread", "44");

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      for (const mark of ambient) {
        mark.classList.add("is-live");
        mark.style.setProperty("--omi-spread", "0");
      }
    });
  });

  // Rotation: a slow constant drift so the mark is never quite still, plus a
  // scroll contribution. Both are eased toward rather than applied directly,
  // so a flick of the wheel arrives as momentum instead of a jump.
  let rot = 0;
  let target = 0;
  let drift = 0;
  let last = performance.now();
  let running = false;
  let visible = true;

  const frame = (now) => {
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    drift += dt * 3.6; // one revolution every 100 seconds
    target = drift + window.scrollY * 0.05;
    rot += (target - rot) * (1 - Math.pow(0.004, dt)); // critically damped follow
    const value = `${rot.toFixed(2)}deg`;
    for (const mark of drifting) mark.style.setProperty("--omi-rot", value);
    if (running && visible) requestAnimationFrame(frame);
    else running = false;
  };

  const start = () => {
    if (running || !visible || !drifting.length) return;
    running = true;
    last = performance.now();
    requestAnimationFrame(frame);
  };

  if ("IntersectionObserver" in window) {
    const watcher = new IntersectionObserver((entries) => {
      visible = entries.some((entry) => entry.isIntersecting);
      if (visible) start();
    });
    for (const mark of drifting) watcher.observe(mark);
  } else {
    start();
  }
  start();

  // The mark leans toward the primary action while it is under the cursor.
  const tighten = (on) => {
    for (const mark of ambient) mark.classList.toggle("is-tight", on);
  };

  for (const cta of document.querySelectorAll(".btn-solid")) {
    cta.addEventListener("pointerenter", () => tighten(true));
    cta.addEventListener("pointerleave", () => tighten(false));
    cta.addEventListener("focus", () => tighten(true));
    cta.addEventListener("blur", () => tighten(false));
  }

  // The onboarding backdrop's edge lights, reused as the scatter palette so a
  // broken ring still reads as Omi (app/lib/features/onboarding/backdrop.dart).
  const bokashi = [
    "#a85e46",
    "#c78067",
    "#d4ae87",
    "#4e687c",
    "#8eafa9",
    "#a6aa79",
    "#c6a760",
    "#b86958",
    "#9b6174",
  ];

  // Hovering any mark plays the app's own move: the ring unrolls into the
  // wave chain (OmiMarkGeometry.laneOf / laneXOf / laneYOf in
  // app/lib/ui/omi_orb_motion.dart) and rolls back on leave. One motion, one
  // easing, staggered around the ring so it reads as a wave rather than a
  // switch. Each dot takes its own colour on the way out.
  const CENTRE = 129.5;
  const LANE_SPAN = 92;
  const laneOffset = (index, cx, cy) => {
    const lane = (index + 3) % 8;
    const x = (lane / 7 - 0.5) * 2 * LANE_SPAN;
    const t = x / LANE_SPAN;
    return [x - (cx - CENTRE), 7 * t * t - 2 - (cy - CENTRE)];
  };

  for (const mark of ambient) {
    const dots = [...mark.querySelectorAll("circle")];
    if (!dots.length) continue;
    const host = mark.closest("a, button") ?? mark;
    dots.forEach((dot, index) => {
      const [dx, dy] = laneOffset(
        index,
        Number(dot.getAttribute("cx")),
        Number(dot.getAttribute("cy")),
      );
      dot.style.setProperty("--lx", `${dx.toFixed(1)}px`);
      dot.style.setProperty("--ly", `${dy.toFixed(1)}px`);
    });
    host.addEventListener("pointerenter", () => {
      const start = (Math.random() * bokashi.length) | 0;
      dots.forEach((dot, index) => {
        dot.style.setProperty(
          "--dot",
          bokashi[(start + index) % bokashi.length],
        );
      });
      mark.classList.add("is-wave");
    });
    host.addEventListener("pointerleave", () => {
      mark.classList.remove("is-wave");
      for (const dot of dots) dot.style.removeProperty("--dot");
    });
  }

  // The footer constellation leans away from the cursor: each dot is pushed
  // along the line from the pointer, harder the closer it sits, and eases
  // home when the pointer leaves. CSS carries the easing; this only writes
  // the per-dot offset.
  const foot = document.querySelector(".foot-stage");
  const fieldDots = foot
    ? [...foot.querySelectorAll(".foot-constellation i")]
    : [];
  if (foot && fieldDots.length && matchMedia("(hover: hover)").matches) {
    let raf = 0;
    let ev = null;
    const apply = () => {
      raf = 0;
      if (!ev) return;
      for (const dot of fieldDots) {
        const b = dot.getBoundingClientRect();
        const dx = b.x + b.width / 2 - ev.clientX;
        const dy = b.y + b.height / 2 - ev.clientY;
        const dist = Math.hypot(dx, dy) || 1;
        const push = Math.max(0, 1 - dist / 240);
        dot.style.setProperty("--px", `${((dx / dist) * push * 90).toFixed(1)}px`);
        dot.style.setProperty("--py", `${((dy / dist) * push * 90).toFixed(1)}px`);
      }
    };
    foot.addEventListener("pointermove", (event) => {
      ev = event;
      if (!raf) raf = requestAnimationFrame(apply);
    });
    foot.addEventListener("pointerleave", () => {
      ev = null;
      for (const dot of fieldDots) {
        dot.style.setProperty("--px", "0px");
        dot.style.setProperty("--py", "0px");
      }
    });
  }

  const FAVICON_FPS = 12;
  const FAVICON_FRAMES = 10;
  const FAVICON_ARC = 45;
  const FAVICON_INTERVAL = 1000 / FAVICON_FPS;

  const spinFavicon = () => {
    const icon = document.querySelector('link[rel="icon"]');
    if (!icon) return;
    const prefix = "data:image/svg+xml,";
    if (!icon.getAttribute("href").startsWith(prefix)) return;
    const svg = decodeURIComponent(
      icon.getAttribute("href").slice(prefix.length),
    );
    const parts = svg.match(/^([\s\S]*<rect[^>]*\/>)([\s\S]*)<\/svg>$/);
    if (!parts) return;

    const frames = [];
    for (let i = 0; i < FAVICON_FRAMES; i += 1) {
      const angle = ((i * FAVICON_ARC) / FAVICON_FRAMES).toFixed(3);
      frames.push(
        prefix +
          encodeURIComponent(
            `${parts[1]}<g transform='rotate(${angle} 16 16)'>${parts[2]}</g></svg>`,
          ),
      );
    }

    let step = 0;
    let timer = 0;
    let due = 0;
    const tick = (now) => {
      timer = requestAnimationFrame(tick);
      if (now < due) return;
      due += FAVICON_INTERVAL;
      if (due < now) due = now + FAVICON_INTERVAL;
      step = (step + 1) % FAVICON_FRAMES;
      icon.setAttribute("href", frames[step]);
    };
    const spin = () => {
      if (timer || document.hidden || quiet.matches) return;
      due = performance.now();
      timer = requestAnimationFrame(tick);
    };
    const rest = () => {
      cancelAnimationFrame(timer);
      timer = 0;
    };
    document.addEventListener("visibilitychange", () =>
      document.hidden ? rest() : spin(),
    );
    quiet.addEventListener("change", () => {
      rest();
      icon.setAttribute("href", frames[0]);
      spin();
    });
    spin();
  };
  spinFavicon();

  // Honour the setting if it is changed while the page is open.
  quiet.addEventListener("change", (event) => {
    if (!event.matches) return;
    running = false;
    visible = false;
    for (const mark of marks) {
      mark.classList.remove("is-live", "is-tight", "is-wave");
      mark.style.removeProperty("--omi-spread");
      mark.style.removeProperty("--omi-rot");
    }
  });
})();
