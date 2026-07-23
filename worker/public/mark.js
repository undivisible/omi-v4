/* The Omi mark's motion. Additive: it only touches [data-omi-mark] elements
   and reads hover on the primary call to action. If this file never loads,
   the mark still renders as the correct static ring.

   Reduced motion is handled twice over — the stylesheet removes every
   animation and transition, and this module returns before starting
   anything, so nothing schedules frames either. */
(() => {
  const marks = document.querySelectorAll("[data-omi-mark]");
  if (!marks.length) return;

  const quiet = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (quiet.matches) return;

  // The ring arrives scattered and re-forms, one dot after the next. The
  // stagger lives in CSS transition-delay; all this does is release it.
  for (const mark of marks) mark.style.setProperty("--omi-spread", "44");

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      for (const mark of marks) {
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
    for (const mark of marks) mark.style.setProperty("--omi-rot", value);
    if (running && visible) requestAnimationFrame(frame);
    else running = false;
  };

  const start = () => {
    if (running || !visible) return;
    running = true;
    last = performance.now();
    requestAnimationFrame(frame);
  };

  if ("IntersectionObserver" in window) {
    const watcher = new IntersectionObserver((entries) => {
      visible = entries.some((entry) => entry.isIntersecting);
      if (visible) start();
    });
    for (const mark of marks) watcher.observe(mark);
  } else {
    start();
  }
  start();

  // The mark leans toward the primary action while it is under the cursor.
  const tighten = (on) => {
    for (const mark of marks) mark.classList.toggle("is-tight", on);
  };

  for (const cta of document.querySelectorAll(".btn-solid, .nav-links .cta")) {
    cta.addEventListener("pointerenter", () => tighten(true));
    cta.addEventListener("pointerleave", () => tighten(false));
    cta.addEventListener("focus", () => tighten(true));
    cta.addEventListener("blur", () => tighten(false));
  }

  // Honour the setting if it is changed while the page is open.
  quiet.addEventListener("change", (event) => {
    if (!event.matches) return;
    running = false;
    visible = false;
    for (const mark of marks) {
      mark.classList.remove("is-live", "is-tight");
      mark.style.removeProperty("--omi-spread");
      mark.style.removeProperty("--omi-rot");
    }
  });
})();
