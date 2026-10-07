// Before the page paints: the reader's saved theme, else their system's.
(function () {
  try {
    var saved = localStorage.getItem("runlight_site_theme");
    var dark = saved ? saved === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
    document.documentElement.dataset.theme = dark ? "dark" : "light";
  } catch (e) {}
})();
