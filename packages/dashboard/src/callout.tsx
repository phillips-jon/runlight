import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./icons.js";

/** A boxed note with an icon and a short title, plain for something to know or amber for something to fix. */
export function Callout({ icon, title, tone, action, children }: { icon: IconName; title: string; tone?: "warn"; action?: ComponentChildren; children: ComponentChildren }) {
  return (
    <div class={tone ? `callout-box ${tone}` : "callout-box"} role={tone ? "note" : undefined}>
      <span class="callout-box-icon" aria-hidden="true">
        <Icon name={icon} />
      </span>
      <div class="callout-box-text">
        <strong>{title}</strong>
        <p>{children}</p>
      </div>
      {action ? <div class="callout-box-action">{action}</div> : null}
    </div>
  );
}
