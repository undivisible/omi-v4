import type { CSSProperties, ReactNode } from "react";

export const portalUrl = "https://api.omi.tsc.hk/portal";
export const apiKeysUrl = "https://api.omi.tsc.hk/portal#api-keys";
export const apiDocsUrl = "https://api.omi.tsc.hk/docs/api";
export const downloadUrl = "https://omi.me/download";

const inkColor = "#171716";
const creamColor = "#fffcec";
const mutedColor = "#a6a49c";
const skyColor = "#9aa0ff";

export const sectionStyle: CSSProperties = {
  padding: "clamp(1.25rem, 5vw, 4.5rem)",
  maxWidth: "76rem",
  margin: "0 auto",
};

export const labelStyle: CSSProperties = {
  fontFamily: '"Geist Pixel", "Geist Mono", monospace',
  fontSize: "11px",
  letterSpacing: "0.12em",
  textTransform: "uppercase",
  color: mutedColor,
};

export const giantStyle: CSSProperties = {
  fontFamily: '"Literata", Georgia, serif',
  fontSize: "clamp(2.5rem, 7vw, 5rem)",
  lineHeight: "1.05",
  fontWeight: 600,
  color: inkColor,
};

export const bigStyle: CSSProperties = {
  fontFamily: '"Literata", Georgia, serif',
  fontSize: "clamp(1.5rem, 4vw, 2.5rem)",
  lineHeight: "1.15",
  fontWeight: 400,
  color: inkColor,
};

export const midStyle: CSSProperties = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "clamp(1rem, 2.5vw, 1.25rem)",
  lineHeight: "1.5",
  color: inkColor,
};

export const smallStyle: CSSProperties = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.875rem",
  lineHeight: "1.5",
  color: mutedColor,
};

export const btnSolidStyle: CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  padding: "0.625rem 1.25rem",
  borderRadius: "999px",
  background: inkColor,
  color: creamColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

export const btnLineStyle: CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  padding: "0.625rem 1.25rem",
  borderRadius: "999px",
  border: `1px solid ${inkColor}`,
  color: inkColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

export const arrowStyle: CSSProperties = {
  color: skyColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

export const noteStyle: CSSProperties = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "1rem",
  lineHeight: "1.6",
  color: inkColor,
};

export const codeStyle: CSSProperties = {
  fontFamily: '"Geist Mono", monospace',
  fontSize: "0.875em",
  background: "rgba(25, 23, 20, 0.06)",
  padding: "0.125em 0.375em",
  borderRadius: "4px",
};

export const strongStyle: CSSProperties = { fontWeight: 700 };

export function T({
  style,
  children,
}: {
  style?: CSSProperties;
  children: ReactNode;
}) {
  return <span style={style}>{children}</span>;
}

export function V({
  style,
  gap,
  children,
}: {
  style?: CSSProperties;
  gap?: number;
  children: ReactNode;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: gap ?? 8,
        ...style,
      }}
    >
      {children}
    </div>
  );
}

export function H({
  style,
  gap,
  children,
}: {
  style?: CSSProperties;
  gap?: number;
  children: ReactNode;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        gap: gap ?? 8,
        ...style,
      }}
    >
      {children}
    </div>
  );
}

export function Ln({
  href,
  style,
  children,
}: {
  href: string;
  style?: CSSProperties;
  children: ReactNode;
}) {
  return (
    <a href={href} style={style}>
      {children}
    </a>
  );
}

export function Badge({
  style,
  children,
}: {
  style?: CSSProperties;
  children: ReactNode;
}) {
  return <span style={style}>{children}</span>;
}

export function Divider() {
  return <hr />;
}

export function Section({
  gap,
  style,
  children,
}: {
  gap?: number;
  style?: CSSProperties;
  children: ReactNode;
}) {
  return (
    <V gap={gap ?? 16} style={{ ...sectionStyle, ...style }}>
      {children}
    </V>
  );
}

export function PrimaryActions() {
  return (
    <H style={{ flexWrap: "wrap", gap: 12 }}>
      <Ln href={portalUrl} style={btnSolidStyle}>
        Open Omi
      </Ln>
      <Ln href={apiDocsUrl} style={btnLineStyle}>
        Documentation
      </Ln>
      <Ln href={apiKeysUrl} style={btnLineStyle}>
        API login
      </Ln>
    </H>
  );
}

export function ColumnGroup({
  groups,
}: {
  groups: Array<[string, string[]]>;
}) {
  return (
    <H style={{ flexWrap: "wrap", gap: 16 }}>
      {groups.map(([title, lines]) => (
        <V key={title} gap={8}>
          <T style={labelStyle}>{title}</T>
          <ul>
            {lines.map((line) => (
              <li key={line}>
                <T>{line}</T>
              </li>
            ))}
          </ul>
        </V>
      ))}
    </H>
  );
}

export function App({ children }: { children: ReactNode }) {
  return <>{children}</>;
}

export default App;
