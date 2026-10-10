/**
 * @file
 * Fits the Runlight frame to the window below it, and reloads the page when
 * the dashboard asks, which it does once its session has run out.
 */
(function () {
  var frame = document.getElementById("runlight-embed");
  if (!frame) return;
  var origin = frame.getAttribute("data-runlight-origin");
  function fit() {
    var top = frame.getBoundingClientRect().top + window.scrollY;
    frame.style.height = Math.max(600, window.innerHeight - top - 24) + "px";
  }
  fit();
  window.addEventListener("resize", fit);
  window.addEventListener("message", function (event) {
    if (event.origin === origin && event.source === frame.contentWindow && event.data && event.data.type === "runlight:reload") location.reload();
  });
})();
