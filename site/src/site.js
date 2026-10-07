// Theme switch (button and Shift+Cmd+D), copy buttons, and the live clock-free bits of the page.
(function () {
  var root = document.documentElement;
  var setTheme = function (dark) {
    root.dataset.theme = dark ? "dark" : "light";
    try {
      localStorage.setItem("runlight_site_theme", dark ? "dark" : "light");
    } catch (e) {}
  };
  var toggle = function () {
    setTheme(root.dataset.theme !== "dark");
  };
  document.addEventListener("click", function (e) {
    var t = e.target.closest && e.target.closest(".theme, .copy");
    if (!t) return;
    if (t.classList.contains("theme")) return toggle();
    var box = t.closest(".code, .install");
    var text = box && (box.querySelector("code") || {}).textContent;
    if (!text || !navigator.clipboard) return;
    navigator.clipboard.writeText(text.replace(/\n$/, "")).then(function () {
      var was = t.textContent;
      t.textContent = "Copied";
      setTimeout(function () {
        t.textContent = was;
      }, 1500);
    });
  });
  document.addEventListener("keydown", function (e) {
    if (e.shiftKey && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "d") {
      e.preventDefault();
      toggle();
    }
  });
})();
