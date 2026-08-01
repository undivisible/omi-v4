import type { CSSProperties, ReactNode } from "react";
import {
  apiDocsUrl,
  apiKeysUrl,
  downloadUrl,
  portalUrl,
} from "./urls";
import { markDots, markDotRadius } from "./head";

/* Onboarding bokashi edge lights (app/lib/features/onboarding/backdrop.dart). */
const glowLights: Array<[number, number, string]> = [
  [-1.25, -1.2, "#a85e46"],
  [-0.25, -1.25, "#c78067"],
  [0.35, -1.25, "#d4ae87"],
  [1.2, -1.05, "#4e687c"],
  [1.25, 0.05, "#8eafa9"],
  [1.2, 1.15, "#a6aa79"],
  [0.05, 1.25, "#c6a760"],
  [-0.75, 1.2, "#b86958"],
  [-1.25, 0.45, "#9b6174"],
];

export function GlowField() {
  return (
    <div
      className="field"
      aria-hidden="true"
      dangerouslySetInnerHTML={{
        __html: glowLights
          .map(
            ([x, y, c], i) =>
              `<i style="--x:${x};--y:${y};--i:${i}"><b style="--c:${c}"></b></i>`,
          )
          .join(""),
      }}
    />
  );
}

export type OmiMarkProps = {
  variant?: "omi-mark--sm" | "omi-mark--rail" | "omi-mark--nav" | "omi-mark--foot";
  glow?: boolean;
  decorative?: boolean;
  className?: string;
};

export function OmiMark({
  variant,
  glow = false,
  decorative = true,
  className,
}: OmiMarkProps) {
  const classes = ["omi-mark", variant, className].filter(Boolean).join(" ");
  const filterId = `omiMarkGlow-${variant ?? "lead"}`;
  const dots = markDots
    .map(
      (d) =>
        `<circle id="${d.id}" cx="${d.cx}" cy="${d.cy}" r="${markDotRadius}" style="--ux:${d.ux};--uy:${d.uy}"/>`,
    )
    .join("");
  const defs = glow
    ? `<defs><filter id="${filterId}" x="-40%" y="-40%" width="180%" height="180%" color-interpolation-filters="sRGB"><feGaussianBlur in="SourceGraphic" stdDeviation="9" result="soft"/><feColorMatrix in="soft" type="matrix" result="halo" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 0.85 0"/><feMerge><feMergeNode in="halo"/><feMergeNode in="halo"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>`
    : "";
  const ringOpen = glow
    ? `<g class="omi-mark-ring" filter="url(#${filterId})">`
    : `<g class="omi-mark-ring">`;
  const role = decorative
    ? 'aria-hidden="true"'
    : 'role="img" aria-label="Omi"';
  const html = `<svg class="${classes}" viewBox="0 0 260 260" ${role} data-omi-mark>${defs}${ringOpen}${dots}</g></svg>`;
  return <span dangerouslySetInnerHTML={{ __html: html }} />;
}

export function OmiMarkHero({ className }: { className?: string } = {}) {
  return <OmiMark glow decorative={false} className={className} />;
}

export function OmiMarkHeroSmall({ className }: { className?: string } = {}) {
  return (
    <OmiMark variant="omi-mark--sm" glow decorative={false} className={className} />
  );
}

export function SectionRail({
  sections,
}: {
  sections: Array<[string, string]>;
}) {
  return (
    <nav className="rail" aria-label="Sections">
      <a className="rail-mark" href="/" aria-label="Omi home">
        <OmiMark variant="omi-mark--rail" decorative={false} />
      </a>
      <ol>
        {sections.map(([anchor, label]) => (
          <li key={anchor}>
            <a href={`#${anchor}`}>{label}</a>
          </li>
        ))}
      </ol>
    </nav>
  );
}

/* A loose constellation, not a ring: percent offsets inside the field. It
   spans the whole footer, denser toward the open right half. */
const constellation: Array<[number, number]> = [
  [6, 10],
  [16, 30],
  [11, 62],
  [24, 84],
  [33, 14],
  [41, 48],
  [36, 92],
  [52, 8],
  [57, 34],
  [49, 68],
  [64, 88],
  [68, 18],
  [74, 52],
  [79, 76],
  [84, 8],
  [88, 38],
  [93, 62],
  [96, 22],
];

const footerCompany: Array<[string, string]> = [
  ["Careers", "https://www.omi.me/pages/careers"],
  ["Invest", "https://omi.me/invest"],
  ["Privacy", "https://www.omi.me/pages/privacy"],
  ["Events", "https://www.omi.me/blogs/events/"],
  ["Manifesto", "https://omi.me/manifesto"],
  ["Compliance", "https://omi.me/trust"],
];

const footerProducts: Array<[string, string]> = [
  ["Omi", "https://www.omi.me/pages/product"],
  ["Omi Glass", "https://omi.me/glass"],
  ["Omi Enterprise", "https://omi.me/enterprise"],
  ["Wrist Band", "https://www.omi.me/products/omi-watch-band"],
  ["Omi Charger", "https://www.omi.me/products/omi-wireless-charger"],
  ["Download", downloadUrl],
];

const footerResources: Array<[string, string]> = [
  ["Architecture", "/architecture"],
  ["API reference", "/docs/api"],
  ["Open Omi", portalUrl],
  ["API login", apiKeysUrl],
  ["Help Center", "https://help.omi.me"],
  ["Status", "https://status.omi.me"],
  ["App Store", "https://h.omi.me/apps"],
  ["GitHub", "https://github.com/BasedHardware/omi"],
  ["Community", "https://discord.omi.me/"],
];

/* The index reads as a masthead column, not a nav bar: a pixel-face label
   over a hairline, then the names in a quiet stack. Each link wears one of
   the mark's dots, dim until the cursor arrives — the same grammar as the
   mark itself. */
function FooterRow({
  heading,
  links,
}: {
  heading: string;
  links: Array<[string, string]>;
}) {
  return (
    <nav aria-label={heading}>
      <h2 className="label hairline-t font-normal pt-3">{heading}</h2>
      <ul className="list-none grid gap-y-[0.4rem] mt-4">
        {links.map(([label, href]) => (
          <li key={label}>
            <a
              href={href}
              className="group inline-flex items-center gap-[0.55rem] text-onDark text-[0.92rem] transition-colors duration-180 hover:text-cream"
            >
              <i
                aria-hidden="true"
                className="w-[0.3rem] h-[0.3rem] rounded-full bg-onDarkDot transition-all duration-300 ease-omi group-hover:bg-cream group-hover:scale-180 group-hover:shadow-[0_0_12px_rgba(255,250,243,0.9)]"
              />
              {label}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}

export function SiteFooter({ compact = false }: { compact?: boolean }) {
  if (compact) {
    return (
      <footer className="foot-compact wrap">
        <p>
          <OmiMark variant="omi-mark--foot" /> thought to action.
        </p>
        <p>Based Hardware Inc. · San Francisco</p>
        <p>© 2026</p>
      </footer>
    );
  }
  return (
    <footer className="foot-stage">
      <div className="foot-stage-glow" aria-hidden="true" />
      <div className="foot-ghost" aria-hidden="true">
        <OmiMark decorative />
      </div>
      <div className="foot-constellation" aria-hidden="true">
        {constellation.map(([fx, fy], i) => (
          <i
            key={i}
            style={
              {
                "--d": String(i),
                "--fx": String(fx),
                "--fy": String(fy),
              } as CSSProperties
            }
          />
        ))}
      </div>
      <div className="foot-stage-inner wrap">
        <div className="grid gap-x-[clamp(2rem,5vw,5rem)] gap-y-[clamp(2.5rem,6vw,4rem)] lg:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)]">
          <div className="foot-stage-hero">
            <OmiMark className="omi-mark--on-dark foot-stage-mark" glow decorative={false} />
            <p className="font-pixel text-[11px] tracking-[0.22em] text-[rgba(255,250,243,0.5)]">
              OMI · BASED HARDWARE · SF
            </p>
            <p className="foot-stage-title">
              thought
              <br />
              to action<span className="text-sky">.</span>
            </p>
            <p className="max-w-96 leading-relaxed text-[rgba(255,250,243,0.65)] mt-[clamp(1rem,2.5vw,1.75rem)]">
              Private memory. Cited answers. Your OK before it acts.
            </p>
            <div className="flex flex-wrap gap-[0.65rem] mt-[clamp(1.25rem,3vw,2rem)]">
              <a className="btn btn-solid" href={portalUrl}>
                Open Omi
              </a>
              <a className="btn btn-line" href={apiDocsUrl}>
                Documentation
              </a>
              <a className="btn btn-line" href={downloadUrl}>
                Download
              </a>
            </div>
          </div>
          <div className="grid gap-x-[clamp(1.5rem,3vw,3rem)] gap-y-10 sm:grid-cols-2 lg:grid-cols-3 lg:self-end">
            <FooterRow heading="Company" links={footerCompany} />
            <FooterRow heading="Products" links={footerProducts} />
            <FooterRow heading="Resources" links={footerResources} />
          </div>
        </div>
        <p className="foot-rule small flex flex-wrap justify-between gap-x-8 gap-y-2">
          <span>
            © 2026 Based Hardware Inc. · San Francisco ·{" "}
            <a href="mailto:help@omi.me">help@omi.me</a>
          </span>
          <span className="font-pixel text-[10px] tracking-[0.16em]">
            <span data-sf-clock>37.7749° N · 122.4194° W</span>
          </span>
        </p>
      </div>
    </footer>
  );
}

export type PageProps = {
  children: ReactNode;
  rail?: Array<[string, string]>;
  compactFooter?: boolean;
};

export function Page({
  children,
  rail = [],
  compactFooter = false,
}: PageProps) {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <GlowField />
      <main id="main">
        {rail.length > 0 ? <SectionRail sections={rail} /> : null}
        {children}
      </main>
      <SiteFooter compact={compactFooter} />
    </>
  );
}
