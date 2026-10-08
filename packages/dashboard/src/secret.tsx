import { useState } from "preact/hooks";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";

interface Props {
  class?: string;
  value: string;
  onInput: (e: Event) => void;
  placeholder?: string;
  autoComplete?: string;
  required?: boolean;
  minLength?: number;
  disabled?: boolean;
  spellcheck?: boolean;
  "aria-describedby"?: string;
  "aria-invalid"?: boolean;
}

/** A password or key field with an eye button to show what was typed. */
export function Secret(props: Props) {
  const [shown, setShown] = useState(false);
  return (
    <span class="secret">
      <input {...props} type={(shown ? "text" : "password") as "password"} />
      <button type="button" class="secret-toggle" aria-label={t(shown ? "secret.hide" : "secret.show")} title={t(shown ? "secret.hide" : "secret.show")} aria-pressed={shown} onClick={() => setShown(!shown)}>
        <Icon name={shown ? "eyeOff" : "eye"} />
      </button>
    </span>
  );
}
