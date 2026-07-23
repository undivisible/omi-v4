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
