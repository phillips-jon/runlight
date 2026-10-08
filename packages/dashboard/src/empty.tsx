import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./icons.js";

/**
 * What a box shows when it has nothing to list: an icon, what would be here, and how it fills up,
 * in place of its column headings and tools, which mean nothing without rows.
 */
export function Empty({ icon, title, hint, size, children }: { icon: IconName; title: string; hint?: string; size?: "card" | "line"; children?: ComponentChildren }) {
  // A card sits in a settings list before its first item; a line sits in a small list inside a box.
  return (
    <div class={size ? `empty-state ${size}` : "empty-state"}>
      <span class="empty-mark" aria-hidden="true">
        <Icon name={icon} />
      </span>
      <p class="empty-title">{title}</p>
      {hint ? <p class="empty-hint">{hint}</p> : null}
      {children}
    </div>
  );
}
