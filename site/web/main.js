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

// The hero shows the real hub — the Flutter web build served from /hub/. It is
// roughly 1.2 MB gzipped before canvaskit and its fonts, so it must not be part
// of what the page costs on first paint. An IntersectionObserver starts it as
// the frame approaches the viewport, which is late enough that a reader who
// never scrolls there never pays for it, and early enough that it has arrived
// by the time they look at it. The iframe keeps the app's errors and its canvas
// out of this document.
(() => {
  const frame = document.getElementById("hub-frame");
  const start = document.getElementById("hub-start");
  const note = document.getElementById("hub-note");

  if (!frame || !start || !note) return;

  let status = null;

  const fail = () => {
    if (frame.dataset.state === "failed") return;
    frame.dataset.state = "failed";
    const live = frame.querySelector("iframe");
    if (live) live.remove();
    if (status) status.remove();
    note.textContent =
      "The hub could not start in this browser. Open Omi to use it instead.";
    start.textContent = "Open Omi";
  };

  window.addEventListener("message", (event) => {
    if (event.source !== frame.querySelector("iframe")?.contentWindow) return;
    if (event.data?.source !== "omi-hub") return;
    if (event.data.status === "ready") {
      frame.dataset.state = "ready";
      if (status) status.remove();
    } else {
      fail();
    }
  });

  const load = () => {
    if (frame.dataset.state === "failed") {
      window.location.href = "/portal";
      return;
    }
    if (frame.dataset.state !== "idle") return;

    frame.dataset.state = "loading";
    status = document.createElement("p");
    status.className = "shot-status";
    status.setAttribute("role", "status");
    status.textContent = "Loading the demo…";
    frame.append(status);

    const live = document.createElement("iframe");
    live.title = "The Omi hub, running on sample data";
    live.src = "/hub/";
    live.loading = "lazy";
    live.allow = "clipboard-write";
    live.addEventListener("error", fail);
    // An aborted or blocked navigation leaves the frame on about:blank and
    // fires load all the same, so the fallback does not wait for the timeout.
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

  // The button stays as the manual path, and it is the only path when the
  // reader has asked their browser to save data or the observer is missing.
  start.addEventListener("click", load);

  if (navigator.connection?.saveData) return;
  if (!("IntersectionObserver" in window)) return;

  // The frame sits below the first screen but well inside a generous root
  // margin, so an observer armed at load would fire immediately and put the
  // whole build back into the initial page weight. Arming it on the first
  // scroll is what makes "approaching the viewport" mean what it says: a
  // reader who never scrolls never starts it.
  const arm = () => {
    const approach = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        approach.disconnect();
        load();
      },
      { rootMargin: "500px 0px" },
    );
    approach.observe(frame);
  };

  window.addEventListener("scroll", arm, { once: true, passive: true });
})();
