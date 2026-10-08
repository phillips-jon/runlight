import type { RefObject } from "preact";
import { useEffect } from "preact/hooks";

/**
 * Moves focus into a dialog when it opens, unless something inside already took it, and gives it back
 * to whatever had it when the dialog closes, so keyboard and screen reader users are not left behind.
 */
export function useDialogFocus(dialog: RefObject<HTMLElement | null>): void {
  useEffect(() => {
    const before = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const root = dialog.current;
    if (root && !root.contains(document.activeElement)) {
      // A field first, so a form is ready to type in, then any control, such as the close button.
      const first =
        root.querySelector<HTMLElement>("input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled])") ??
        root.querySelector<HTMLElement>("button:not([disabled]), a[href], [tabindex]:not([tabindex='-1'])");
      if (first) first.focus();
      else {
        root.tabIndex = -1;
        root.focus();
      }
    }
    return () => {
      if (before?.isConnected) before.focus();
    };
  }, []);
}
