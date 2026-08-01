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
        if (near > 0.5) {
          link.setAttribute("aria-current", "location");
        } else {
          link.removeAttribute("aria-current");
        }
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

(() => {
  const icon = document.querySelector('link[rel~="icon"]');
  const quiet = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (!icon || quiet.matches) return;

  let frame = 0;
  let timer = 0;

  const paint = () => {
    const turn = frame * 24;
    frame = (frame + 1) % 15;
    const dots = Array.from({ length: 8 }, (_, index) => {
      const angle = ((index * 45 - 90) * Math.PI) / 180;
      const x = (16 + Math.cos(angle) * 8.4).toFixed(2);
      const y = (16 + Math.sin(angle) * 8.4).toFixed(2);
      return `<circle cx="${x}" cy="${y}" r="2.12"/>`;
    }).join("");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#191714"/><g fill="#fffaf3" transform="rotate(${turn} 16 16)">${dots}</g></svg>`;
    icon.href = `data:image/svg+xml,${encodeURIComponent(svg)}`;
  };

  const start = () => {
    if (timer || document.visibilityState !== "visible") return;
    paint();
    timer = window.setInterval(paint, 1000 / 15);
  };

  const stop = () => {
    if (!timer) return;
    window.clearInterval(timer);
    timer = 0;
  };

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") start();
    else stop();
  });
  quiet.addEventListener("change", (event) => {
    if (event.matches) stop();
    else start();
  });
  start();
})();

// The footer's fine print carries the office's own clock. Without JS the
// coordinates stand on their own, which is why they are what ships in the
// markup.
(() => {
  const slot = document.querySelector("[data-sf-clock]");
  if (!slot) return;
  const time = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const tick = () => {
    slot.textContent = `SAN FRANCISCO ${time.format(new Date())} · 37.7749° N · 122.4194° W`;
  };
  tick();
  window.setInterval(tick, 20000);
})();

// The rail is fixed over rooms of very different brightness. Sections that
// are dark declare themselves, and the rail flips to cream while one of them
// is under its middle — the same trick a sticky header uses, one band tall.
(() => {
  const rail = document.querySelector(".rail");
  if (!rail || !("IntersectionObserver" in window)) return;

  const dark = document.querySelectorAll(
    '.ed-hero, .ed-dissolve, .foot-stage, [data-tone="dark"]',
  );
  if (!dark.length) return;

  const over = new Set();
  const watcher = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) over.add(entry.target);
        else over.delete(entry.target);
      }
      if (over.size) rail.dataset.tone = "dark";
      else delete rail.dataset.tone;
    },
    { rootMargin: "-30% 0px -30% 0px" },
  );
  for (const section of dark) watcher.observe(section);
})();

// Bottom-of-page Flutter demo at /hub/. Starts loading when the frame (or
// #hub section) is within ~1.5 viewports, so the hub is warm on arrival.
(() => {
  const frame = document.getElementById("hub-frame");
  if (!frame) return;

  const cue = document.getElementById("hub") || frame;
  let status = null;
  let armed = false;

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
    if (event.origin !== window.location.origin) return;
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
    armed = true;

    frame.dataset.state = "loading";
    status = document.createElement("p");
    status.className = "shot-status";
    status.setAttribute("role", "status");
    status.textContent = "Loading the demo…";
    frame.append(status);

    const live = document.createElement("iframe");
    live.title = "Omi, running on sample data";
    live.src = "/hub/?v=guided-hub-v4";
    live.allow = "clipboard-write; language-model";
    live.addEventListener("error", fail);
    live.addEventListener("load", () => {
      try {
        if (live.contentWindow.location.href === "about:blank") fail();
      } catch {
        fail();
      }
    });
    frame.append(live);

    // Until the reader asks for it, the demo is a picture: the shield takes
    // the wheel so the page keeps scrolling past a canvas that would
    // otherwise swallow it. Click to hand control over, Escape to take it
    // back.
    const shield = document.createElement("button");
    shield.type = "button";
    shield.className = "shot-shield";
    shield.innerHTML = "<span>Click to interact</span>";
    shield.addEventListener("click", () => {
      frame.dataset.live = "1";
      live.focus();
    });
    frame.append(shield);

    const release = () => {
      if (frame.dataset.live !== "1") return;
      delete frame.dataset.live;
      shield.blur();
    };
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") release();
    });
    document.addEventListener("pointerdown", (event) => {
      if (!frame.contains(event.target)) release();
    });

    window.setTimeout(() => {
      if (frame.dataset.state === "loading") {
        status.textContent = "Still loading the demo…";
      }
    }, 15000);

    window.setTimeout(() => {
      if (frame.dataset.state === "loading") fail();
    }, 42000);
  };

  const arm = () => {
    if (armed) return;
    load();
  };

  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            arm();
            observer.disconnect();
            break;
          }
        }
      },
      // Start ~1.5 viewports early so scroll-in feels ready, not cold.
      { rootMargin: "150% 0px", threshold: 0 },
    );
    observer.observe(cue || frame);
  } else {
    arm();
  }

  frame.addEventListener("pointerenter", arm, { once: true });
  frame.addEventListener("focusin", arm, { once: true });

  if (frame.getBoundingClientRect().top < window.innerHeight * 1.5) {
    arm();
  }
})();
