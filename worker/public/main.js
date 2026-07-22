(() => {
  const nav = document.getElementById("nav");
  const toggle = document.getElementById("navToggle");
  const links = document.getElementById("navLinks");

  toggle.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    toggle.setAttribute("aria-expanded", String(open));
  });

  links.addEventListener("click", (event) => {
    if (event.target.tagName === "A") {
      links.classList.remove("open");
      toggle.setAttribute("aria-expanded", "false");
    }
  });

  const hero = document.querySelector(".hero");
  const heroWatcher = new IntersectionObserver(
    ([entry]) => {
      nav.classList.toggle("nav-light", entry.intersectionRatio < 0.08);
    },
    { threshold: [0, 0.08, 0.2] },
  );
  heroWatcher.observe(hero);

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
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
    { rootMargin: "0px 0px -8% 0px", threshold: 0.1 },
  );

  let stagger = 0;
  for (const el of revealed) {
    el.style.transitionDelay = `${(stagger++ % 4) * 60}ms`;
    revealer.observe(el);
  }
})();
