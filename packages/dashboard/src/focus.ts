import type { RefObject } from "preact";
import { useEffect } from "preact/hooks";

const FOCUSABLE = "input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled]), a[href], [tabindex]:not([tabindex='-1'])";

/** Open dialogs, innermost last; only the innermost keeps Tab. */
const open: HTMLElement[] = [];

/** The controls Tab can reach inside a dialog, in order, leaving out hidden ones and the unchecked radios of a group. */
function focusables(root: HTMLElement): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => {
    if (el.getClientRects().length === 0 || el.closest("[hidden], [inert]")) return false;
    if (el instanceof HTMLInputElement && el.type === "radio" && el.name && !el.checked) {
      return !root.querySelector(`input[type=radio][name="${CSS.escape(el.name)}"]:checked`);
    }
    return true;
  });
}

/**
 * Moves focus into a dialog when it opens, unless something inside already took it, keeps Tab and
 * Shift+Tab inside it while it is open, and gives focus back to whatever had it when the dialog
 * closes, so keyboard and screen reader users are not left behind.
 */
export function useDialogFocus(dialog: RefObject<HTMLElement | null>): void {
  useEffect(() => {
    const before = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const root = dialog.current;
    if (!root) return;
    open.push(root);
    if (!root.contains(document.activeElement)) {
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
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Tab" || open[open.length - 1] !== root) return;
      const items = focusables(root);
      if (!items.length) {
        e.preventDefault();
        return;
      }
      const first = items[0]!;
      const last = items[items.length - 1]!;
      const at = document.activeElement;
      if (!root.contains(at)) {
        e.preventDefault();
        (e.shiftKey ? last : first).focus();
      } else if (e.shiftKey && (at === first || at === root)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && at === last) {
        e.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      open.splice(open.indexOf(root), 1);
      if (before?.isConnected) before.focus();
    };
  }, []);
}
