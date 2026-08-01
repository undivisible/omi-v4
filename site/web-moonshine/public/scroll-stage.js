(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const nodes = document.querySelectorAll("[data-ss-observe]");
  if (!nodes.length) return;

  if (reduced || !("IntersectionObserver" in window)) {
    for (const el of nodes) el.setAttribute("data-ss-inview", "1");
    return;
  }

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.setAttribute("data-ss-inview", "1");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -12% 0px", threshold: 0.2 },
  );

  for (const el of nodes) observer.observe(el);
})();
