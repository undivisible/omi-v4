(() => {
  const nav = document.getElementById("nav");

  // The nav only gains its material once the page has left the very top.
  const sentinel = document.createElement("div");
  sentinel.setAttribute("aria-hidden", "true");
  sentinel.style.cssText = "position:absolute;top:0;height:1px;width:1px";
  document.body.prepend(sentinel);

  new IntersectionObserver(([entry]) => {
    nav.classList.toggle("stuck", !entry.isIntersecting);
  }).observe(sentinel);

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Side index: mark the section the reader is in.
  const railLinks = [...document.querySelectorAll(".rail a")];
  const sections = railLinks
    .map((link) => document.querySelector(link.getAttribute("href")))
    .filter(Boolean);

  if (sections.length) {
    const spy = new IntersectionObserver(
      () => {
        const line = window.innerHeight * 0.35;
        let active = 0;
        sections.forEach((section, index) => {
          if (section.getBoundingClientRect().top <= line) active = index;
        });
        railLinks.forEach((link, index) =>
          link.setAttribute(
            "aria-current",
            index === active ? "true" : "false",
          ),
        );
      },
      { threshold: [0, 0.25, 0.5, 0.75, 1] },
    );
    for (const section of sections) spy.observe(section);
  }

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
// several megabytes, so nothing is fetched until the reader asks for it; until
// then the frame holds a still drawn in CSS. The iframe keeps the app's errors
// and its canvas out of this document.
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

  start.addEventListener("click", () => {
    if (frame.dataset.state === "failed") {
      window.location.href = "/portal";
      return;
    }
    if (frame.dataset.state !== "idle") return;

    frame.dataset.state = "loading";
    status = document.createElement("p");
    status.className = "shot-status";
    status.setAttribute("role", "status");
    status.textContent = "Loading the hub…";
    frame.append(status);

    const live = document.createElement("iframe");
    live.title = "The Omi hub, running live";
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
  });
})();
