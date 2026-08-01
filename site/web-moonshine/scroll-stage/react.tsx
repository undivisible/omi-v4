import type { CSSProperties, ReactNode } from "react";

export type ScrollStageProps = {
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
};

export function ScrollStage({ children, className, style }: ScrollStageProps) {
  const cls = className ? `ss-stage ${className}` : "ss-stage";
  return (
    <div className={cls} style={style}>
      {children}
    </div>
  );
}

export type StickyFrameProps = {
  children: ReactNode;
  pin?: boolean;
  flush?: boolean;
  id?: string;
  className?: string;
  stickyClassName?: string;
  style?: CSSProperties;
};

export function StickyFrame({
  children,
  pin = false,
  flush = false,
  id,
  className,
  stickyClassName,
  style,
}: StickyFrameProps) {
  const frameCls = [
    "ss-frame",
    pin ? "ss-frame--pin" : "",
    className ?? "",
  ]
    .filter(Boolean)
    .join(" ");
  const stickyCls = [
    "ss-frame__sticky",
    flush ? "ss-frame__sticky--flush" : "",
    stickyClassName ?? "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <section id={id} className={frameCls} style={style}>
      <div className={stickyCls}>{children}</div>
    </section>
  );
}

export type StepItem = {
  index: string;
  title: string;
  body: string;
};

export type StepStackProps = {
  label?: string;
  heading?: string;
  steps: StepItem[];
  className?: string;
};

export function StepStack({ label, heading, steps, className }: StepStackProps) {
  const cls = className ? `ss-steps-wrap ${className}` : "ss-steps-wrap";
  return (
    <div className={cls}>
      {label ? <p className="ss-label">{label}</p> : null}
      {heading ? <h2 className="ss-step__title">{heading}</h2> : null}
      <ol className="ss-steps">
        {steps.map((step) => (
          <li key={step.index} className="ss-step">
            <span className="ss-step__num">{step.index}</span>
            <span className="ss-step__title">{step.title}</span>
            <span className="ss-step__body">{step.body}</span>
          </li>
        ))}
      </ol>
    </div>
  );
}

export type ScrollCueProps = {
  text: string;
  align?: "start" | "center" | "end";
  as?: "p" | "h2" | "div";
  observe?: boolean;
  className?: string;
  id?: string;
};

export function ScrollCue({
  text,
  align = "end",
  as = "p",
  observe = true,
  className,
  id,
}: ScrollCueProps) {
  const Tag = as;
  const cueCls = [
    "ss-cue",
    `ss-cue--${align}`,
    className ?? "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <aside id={id} className={cueCls} aria-label={text}>
      <Tag
        className="ss-cue__text"
        data-ss-observe={observe ? "" : undefined}
      >
        {text}
      </Tag>
    </aside>
  );
}
