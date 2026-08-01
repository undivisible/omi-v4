import type { CSSProperties, ReactNode } from "react";
import {
  apiDocsUrl,
  apiKeysUrl,
  downloadUrl,
  portalUrl,
} from "./urls";
import { markDots, markDotRadius } from "./head";

const glowLights: Array<[number, number, string]> = [
  [-1.25, -1.2, "#f25e6b"],
  [-0.25, -1.25, "#f2c2ac"],
  [0.35, -1.25, "#ffd0b8"],
  [1.2, -1.05, "#96c4ff"],
  [1.25, 0.05, "#b9d6ff"],
  [1.2, 1.15, "#d3e081"],
  [0.05, 1.25, "#f4d69f"],
  [-0.75, 1.2, "#f2c2ac"],
  [-1.25, 0.45, "#ff9a91"],
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

function FooterColumn({
  heading,
  links,
}: {
  heading: string;
  links: Array<[string, string]>;
}) {
  return (
    <nav className="foot-col" aria-label={heading}>
      <h2 className="label">{heading}</h2>
      <ul>
        {links.map(([label, href]) => (
          <li key={label}>
            <a href={href}>{label}</a>
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
      <div className="foot-stage-inner wrap">
        <div className="foot-stage-hero">
          <OmiMark className="omi-mark--on-dark foot-stage-mark" glow decorative={false} />
          <p className="foot-stage-kicker">OMI</p>
          <p className="foot-stage-title">thought to action.</p>
          <p className="foot-stage-sub">
            Private memory. Cited answers. Your OK before it acts.
          </p>
          <div className="foot-stage-actions">
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
          <div className="foot-constellation" aria-hidden="true">
            {Array.from({ length: 8 }, (_, i) => (
                <i key={i} style={{ "--d": String(i) } as CSSProperties} />
            ))}
          </div>
        </div>
        <div className="foot">
          <div className="foot-id">
            <p className="small">
              Based Hardware Inc.
              <br />
              San Francisco
              <br />
              <a href="mailto:help@omi.me">help@omi.me</a>
            </p>
          </div>
          <FooterColumn heading="Company" links={footerCompany} />
          <FooterColumn heading="Products" links={footerProducts} />
          <FooterColumn heading="Resources" links={footerResources} />
        </div>
        <p className="foot-rule small">
          © 2026 Based Hardware. All rights reserved.
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
