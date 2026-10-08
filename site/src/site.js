// The theme switch (and Shift+Cmd+D), install tabs, and copy buttons.
(function () {
  var root = document.documentElement;
  var toggle = function () {
    var dark = root.dataset.theme !== "dark";
    root.dataset.theme = dark ? "dark" : "light";
    try {
      localStorage.setItem("runlight_site_theme", dark ? "dark" : "light");
    } catch (e) {}
  };
  var flash = function (button, text) {
    var was = button.getAttribute("data-label") || button.textContent;
    button.setAttribute("data-label", was);
    button.lastChild.textContent = text;
    setTimeout(function () {
      button.lastChild.textContent = was.trim();
    }, 1500);
  };
  var copy = function (button, text) {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).then(function () {
      flash(button, "Copied");
    });
  };

  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest(".theme, .copy, .tab, .way, .prompt");
    if (!el) return;
    if (el.classList.contains("theme")) return toggle();
    if (el.classList.contains("way")) {
      el.parentNode.querySelectorAll(".way").forEach(function (w) {
        var on = w === el;
        w.setAttribute("aria-selected", on ? "true" : "false");
        document.getElementById(w.getAttribute("aria-controls")).hidden = !on;
      });
      // The setup prompt is for adding Runlight to an app.
      var actions = el.closest(".installs").parentNode.querySelector(".actions");
      if (actions) actions.hidden = el.id !== "w-app";
      return;
    }
    if (el.classList.contains("tab")) {
      var tabs = el.closest(".tabs");
      tabs.querySelectorAll(".tab").forEach(function (t) {
        var on = t === el;
        t.setAttribute("aria-selected", on ? "true" : "false");
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
      return;
    }
    if (el.classList.contains("prompt")) {
      fetch("/prompt.txt").then(function (r) {
        return r.text();
      }).then(function (text) {
        copy(el, text);
      });
      return;
    }
    if (el.classList.contains("markdown")) {
      // The page as Markdown, from the copy beside it. Safari keeps the click's permission only when the
      // clipboard is handed the pending text, so it gets a ClipboardItem; other browsers can take either.
      var text = fetch(el.getAttribute("data-src")).then(function (r) {
        return r.text();
      });
      if (window.ClipboardItem && navigator.clipboard && navigator.clipboard.write) {
        navigator.clipboard
          .write([new ClipboardItem({ "text/plain": text.then(function (t) { return new Blob([t], { type: "text/plain" }); }) })])
          .then(function () {
            flash(el, "Copied");
          }, function () {
            text.then(function (t) {
              copy(el, t);
            });
          });
      } else {
        text.then(function (t) {
          copy(el, t);
        });
      }
      return;
    }
    var box = el.closest(".install, .out");
    var code = box && box.querySelector("code");
    if (code) copy(el, code.textContent.replace(/\n$/, ""));
  });

  // The contact form says how long the page was open; the service turns away anything sent in under three seconds.
  var opened = Date.now();
  document.addEventListener("submit", function (e) {
    var t = e.target.querySelector && e.target.querySelector('input[name="t"]');
    if (t) t.value = String(Date.now() - opened);
  });

  document.addEventListener("keydown", function (e) {
    if (e.shiftKey && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "d") {
      e.preventDefault();
      toggle();
    }
  });
})();
