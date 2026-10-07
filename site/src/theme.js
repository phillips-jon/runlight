// Before the page paints: dark, unless the reader turned the sheet over to light.
(function () {
  try {
    document.documentElement.dataset.theme = localStorage.getItem("runlight_site_theme") === "light" ? "light" : "dark";
  } catch (e) {
    document.documentElement.dataset.theme = "dark";
  }
})();
