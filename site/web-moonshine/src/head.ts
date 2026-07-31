const inkColor = "#171716";
const creamColor = "#fffcec";

const markCentre = 129.5;
const markDotRadius = 17.2;
const markAxisRadius = 86.71;
const markDiagonalRadius = 91.92;

const markDots = [
  { id: "d1", cx: 129.5, cy: 42.79, ux: 0, uy: -1 },
  { id: "d2", cx: 194.5, cy: 64.5, ux: 0.7071, uy: -0.7071 },
  { id: "d3", cx: 216.21, cy: 129.5, ux: 1, uy: 0 },
  { id: "d4", cx: 194.5, cy: 194.5, ux: 0.7071, uy: 0.7071 },
  { id: "d5", cx: 129.5, cy: 216.21, ux: 0, uy: 1 },
  { id: "d6", cx: 64.5, cy: 194.5, ux: -0.7071, uy: 0.7071 },
  { id: "d7", cx: 42.79, cy: 129.5, ux: -1, uy: 0 },
  { id: "d8", cx: 64.5, cy: 64.5, ux: -0.7071, uy: -0.7071 },
];

function faviconDataUri(): string {
  const scale = 32 / 260.0;
  const dots = markDots
    .map((d) => {
      const cx = (d.cx * scale).toFixed(2);
      const cy = (d.cy * scale).toFixed(2);
      return `<circle cx="${cx}" cy="${cy}" r="2.12" fill="${creamColor}"/>`;
    })
    .join("");
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='7' fill='${inkColor}'/>${dots}</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const canonicalHost = "https://omi.tsc.hk";

export function buildHead(
  title: string,
  description: string,
  path: string,
): string {
  const canonical = `${canonicalHost}${path}`;
  return [
    `<meta charset="utf-8"/>`,
    `<meta name="viewport" content="width=device-width, initial-scale=1"/>`,
    `<title>${title}</title>`,
    `<meta name="description" content="${description}"/>`,
    `<link rel="icon" href="${faviconDataUri()}"/>`,
    `<link rel="canonical" href="${canonical}"/>`,
    `<link rel="preload" href="/inter-latin-variable.woff2" as="font" type="font/woff2" crossorigin=""/>`,
    `<link rel="preload" href="/geist-pixel-square.woff2" as="font" type="font/woff2" crossorigin=""/>`,
    `<link rel="stylesheet" href="/styles.css"/>`,
    `<meta name="theme-color" content="${inkColor}"/>`,
    `<meta property="og:title" content="${title}"/>`,
    `<meta property="og:description" content="${description}"/>`,
    `<meta property="og:type" content="website"/>`,
    `<meta property="og:url" content="${canonical}"/>`,
    `<script src="/main.js" defer></script>`,
    `<script src="/mark.js" defer></script>`,
  ].join("");
}

export { markDots, markCentre, markDotRadius, markAxisRadius, markDiagonalRadius, inkColor, creamColor };
