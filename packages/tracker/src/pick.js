// The element picker. The dashboard opens the site with ?runlight=pick; the
// tracker loads this instead of counting anything. Hover to highlight, click
// to choose, and the choice goes back to the dashboard that opened the page.
(function () {
  var w = window;
  var d = document;
  var opener = w.opener;
  if (!opener) return;

  var words = {
    en: ["Click what you want to count", "Use this", "Pick again", "Cancel", "Matches {n} on this page", "Sent to Runlight. You can close this tab."],
    fr: ["Cliquez sur ce que vous voulez compter", "Utiliser", "Choisir à nouveau", "Annuler", "{n} sur cette page", "Envoyé à Runlight. Vous pouvez fermer cet onglet."],
    es: ["Haz clic en lo que quieres contar", "Usar esto", "Elegir otra vez", "Cancelar", "{n} en esta página", "Enviado a Runlight. Puedes cerrar esta pestaña."],
    de: ["Klicke auf das, was gezählt werden soll", "Verwenden", "Neu wählen", "Abbrechen", "{n} auf dieser Seite", "An Runlight gesendet. Du kannst diesen Tab schließen."],
    pt: ["Clique no que quer contar", "Usar", "Escolher de novo", "Cancelar", "{n} nesta página", "Enviado ao Runlight. Pode fechar esta aba."],
  };
  var lang = (/[?&]runlight_lang=([a-z]{2})/.exec(location.search) || [])[1];
  var t = words[lang] || words.en;

  // Class names that look generated (hashes, numbers) make brittle selectors.
  var stable = function (name) {
    return /^[a-zA-Z][\w-]{1,40}$/.test(name) && !/\d{3,}|^(css|sc|jsx|svelte|astro)-|__\w{5,}/.test(name);
  };
  var esc = function (v) {
    return w.CSS && CSS.escape ? CSS.escape(v) : v.replace(/[^\w-]/g, "\\$&");
  };
  var unique = function (sel) {
    try {
      return d.querySelectorAll(sel).length === 1;
    } catch (e) {
      return false;
    }
  };
  var selectorFor = function (el) {
    var parts = [];
    for (var node = el; node && node.nodeType === 1 && node !== d.documentElement; node = node.parentElement) {
      if (node.id && stable(node.id)) {
        parts.unshift("#" + esc(node.id));
        break;
      }
      var part = node.tagName.toLowerCase();
      var tagged = node.getAttribute("data-runlight") || node.getAttribute("data-testid");
      if (tagged) part += "[" + (node.hasAttribute("data-runlight") ? "data-runlight" : "data-testid") + '="' + tagged.replace(/"/g, '\\"') + '"]';
      else {
        var classes = Array.prototype.filter.call(node.classList, stable).slice(0, 2);
        if (classes.length) part += "." + classes.map(esc).join(".");
      }
      parts.unshift(part);
      var sel = parts.join(" > ");
      if (unique(sel) || parts.length >= 4) return sel;
      var parent = node.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (c) {
          return c.tagName === node.tagName;
        });
        if (same.length > 1) parts[0] += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
        if (unique(parts.join(" > "))) return parts.join(" > ");
      }
    }
    return parts.join(" > ");
  };

  var host = d.createElement("div");
  host.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none";
  var root = host.attachShadow ? host.attachShadow({ mode: "closed" }) : host;
  root.innerHTML =
    "<style>" +
    ".box{position:fixed;border:2px solid #2563eb;background:rgba(37,99,235,.1);border-radius:4px;pointer-events:none;transition:all .06s}" +
    ".bar{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);display:flex;align-items:center;gap:10px;max-width:min(720px,calc(100vw - 32px));padding:10px 12px 10px 16px;border-radius:12px;background:#111;color:#fff;font:14px/1.4 system-ui,sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:auto}" +
    ".msg{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
    "code{font:12px ui-monospace,monospace;color:#93c5fd}" +
    "button{height:32px;padding:0 12px;border:0;border-radius:8px;font:inherit;cursor:pointer;background:#333;color:#fff}" +
    "button.go{background:#fff;color:#111}" +
    "</style><div class='box' hidden></div><div class='bar'><span class='msg'></span><span class='acts'></span></div>";
  d.documentElement.appendChild(host);
  var box = root.querySelector(".box");
  var msg = root.querySelector(".msg");
  var acts = root.querySelector(".acts");

  var chosen = null;
  var button = function (label, cls, fn) {
    var b = d.createElement("button");
    b.textContent = label;
    if (cls) b.className = cls;
    b.addEventListener("click", fn);
    acts.appendChild(b);
  };
  var outline = function (el) {
    if (!el) return (box.hidden = true);
    var r = el.getBoundingClientRect();
    box.hidden = false;
    box.style.cssText += ";left:" + (r.left - 2) + "px;top:" + (r.top - 2) + "px;width:" + (r.width + 4) + "px;height:" + (r.height + 4) + "px";
  };
  var idle = function () {
    chosen = null;
    msg.textContent = t[0];
    acts.textContent = "";
    button(t[3], "", function () {
      w.close();
    });
  };
  var choose = function (el) {
    var sel = selectorFor(el);
    var link = el.closest("a[href]");
    var n = 0;
    try {
      n = d.querySelectorAll(sel).length;
    } catch (e) {}
    chosen = { selector: sel, href: link ? link.href : "", text: (el.textContent || "").trim().slice(0, 80) };
    msg.innerHTML = "<code></code> · " + t[4].replace("{n}", n);
    msg.querySelector("code").textContent = sel;
    acts.textContent = "";
    button(t[2], "", idle);
    button(t[1], "go", function () {
      opener.postMessage({ runlight: "pick", selector: chosen.selector, href: chosen.href, text: chosen.text }, "*");
      msg.textContent = t[5];
      acts.textContent = "";
      setTimeout(function () {
        w.close();
      }, 900);
    });
  };

  d.addEventListener(
    "mouseover",
    function (e) {
      if (!chosen) outline(e.target);
    },
    true
  );
  // Nothing on the page reacts while picking.
  ["click", "mousedown", "mouseup", "pointerdown", "submit"].forEach(function (type) {
    d.addEventListener(
      type,
      function (e) {
        if (e.composedPath && e.composedPath()[0] && host.contains && e.composedPath().indexOf(host) >= 0) return;
        e.preventDefault();
        e.stopPropagation();
        if (type === "click" && !chosen) {
          outline(e.target);
          choose(e.target);
        }
      },
      true
    );
  });
  idle();
})();
