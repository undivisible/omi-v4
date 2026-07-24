(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Scroll progress, read once per frame and published as a custom property.
  // The glow field rises and brightens on it, and the rail fades on it, so
  // both are driven by one measurement rather than two listeners.
  const field = document.querySelector(".field");
  const railLinks = [...document.querySelectorAll(".rail ol a")];
  const sections = railLinks
    .map((link) => document.querySelector(link.getAttribute("href")))
    .filter(Boolean);
  const railMark = document.querySelector(".omi-mark--rail");

  // Where the reader is, expressed on the rail's own scale: 0 at the first
  // section, sections.length - 1 at the last. Fractional between them, which
  // is what lets the rail fade rather than step.
  const railPosition = () => {
    const line = window.innerHeight * 0.35;
    let index = 0;
    for (let i = 0; i < sections.length; i += 1) {
      const top = sections[i].getBoundingClientRect().top;
      if (top > line) break;
      index = i;
      const next = sections[i + 1];
      if (!next) break;
      const span = next.getBoundingClientRect().top - top;
      if (span > 0) index = i + Math.min(1, (line - top) / span);
    }
    return index;
  };

  let queued = false;

  const measure = () => {
    queued = false;
    const height = document.documentElement.scrollHeight - window.innerHeight;
    const progress = height > 0 ? Math.min(1, window.scrollY / height) : 0;

    if (field && !reduced) field.style.setProperty("--scroll", progress);

    // The rail mark turns with how far down the page the reader is: one full
    // turn from top to bottom, so its angle is readable as a position.
    if (railMark && !reduced) {
      railMark.style.setProperty("--omi-rot", `${(progress * 360).toFixed(2)}deg`);
    }

    if (sections.length) {
      const here = railPosition();
      railLinks.forEach((link, index) => {
        const near = Math.max(0, 1 - Math.abs(index - here));
        link.style.setProperty("--near", near.toFixed(3));
        link.setAttribute("aria-current", near > 0.5 ? "true" : "false");
      });
    }
  };

  const schedule = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(measure);
  };

  measure();
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule);

  const revealed = document.querySelectorAll(".reveal");

  if (reduced || !("IntersectionObserver" in window)) {
    for (const el of revealed) el.classList.add("in");
    return;
  }

  const revealer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          revealer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -6% 0px", threshold: 0.08 },
  );

  for (const el of revealed) {
    // Anything already on screen at load is simply there — no deep link
    // should land on a blank section waiting for a scroll.
    if (el.getBoundingClientRect().top < window.innerHeight) {
      el.classList.add("in");
      continue;
    }
    revealer.observe(el);
  }
})();

// The hero embeds the real hub — the Flutter web build at /hub/. It starts as
// soon as the page loads so the demo is live without a click or scroll gate.
(() => {
  const frame = document.getElementById("hub-frame");
  if (!frame) return;

  let status = null;

  const fail = () => {
    if (frame.dataset.state === "failed") return;
    frame.dataset.state = "failed";
    frame.querySelector("iframe")?.remove();
    status?.remove();
    status = document.createElement("p");
    status.className = "shot-status";
    status.setAttribute("role", "status");
    status.textContent =
      "The demo could not start in this browser. Open Omi to use it instead.";
    frame.append(status);
  };

  window.addEventListener("message", (event) => {
    if (event.source !== frame.querySelector("iframe")?.contentWindow) return;
    if (event.data?.source !== "omi-hub") return;
    if (event.data.status === "ready") {
      frame.dataset.state = "ready";
      status?.remove();
      status = null;
    } else {
      fail();
    }
  });

  const load = () => {
    if (frame.dataset.state !== "idle") return;

    frame.dataset.state = "loading";
    status = document.createElement("p");
    status.className = "shot-status";
    status.setAttribute("role", "status");
    status.textContent = "Loading the demo…";
    frame.append(status);

    const live = document.createElement("iframe");
    live.title = "Omi, running on sample data";
    live.src = "/hub/";
    live.allow = "clipboard-write";
    live.addEventListener("error", fail);
    live.addEventListener("load", () => {
      try {
        if (live.contentWindow.location.href === "about:blank") fail();
      } catch {
        fail();
      }
    });
    frame.append(live);

    setTimeout(() => {
      if (frame.dataset.state === "loading") fail();
    }, 45000);
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", load);
  } else {
    load();
  }
})();
