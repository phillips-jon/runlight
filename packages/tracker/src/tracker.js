// The Runlight tracker. No cookies, nothing in storage except the owner's
// opt-out flag, and no id that outlives the page.
//
//   <script defer src="/runlight/s.js"></script>
//
// Attributes on the script tag:
//   data-site="id"         which site, for the standalone server
//   data-hash              count changes to location.hash as pageviews
//   data-404               this page is a 404, record it as one
//   data-dnt               honour Do Not Track
//   data-outbound="false"  do not record outbound link clicks
//   data-downloads="false" do not record file downloads
(function () {
  var w = window;
  var d = document;
  var n = navigator;
  var script = d.currentScript;
  if (!script) return;

  var attr = function (name) {
    return script.getAttribute("data-" + name);
  };
  var endpoint = script.src.replace(/s\.js(\?.*)?$/, "e");
  var site = attr("site");
  var useHash = attr("hash") !== null;
  var queued = (w.runlight && w.runlight.q) || [];

  // ?runlight=ignore stops counting this browser on this site;
  // ?runlight=track starts again. The owner's opt-out, never a visitor id.
  var ignored = false;
  try {
    var flag = /[?&]runlight=(ignore|track)\b/.exec(location.search);
    if (flag) flag[1] === "ignore" ? localStorage.setItem("runlight_ignore", "1") : localStorage.removeItem("runlight_ignore");
    ignored = localStorage.getItem("runlight_ignore") === "1";
  } catch (e) {}
  if (n.webdriver || ignored || (attr("dnt") !== null && (n.doNotTrack === "1" || w.doNotTrack === "1"))) {
    w.runlight = function () {};
    return;
  }

  var send = function (kind, extra) {
    var body = { k: kind, u: pageUrl };
    if (site) body.s = site;
    for (var key in extra) body[key] = extra[key];
    var json = JSON.stringify(body);
    // A string body goes as text/plain, which needs no CORS preflight.
    if (n.sendBeacon && n.sendBeacon(endpoint, json)) return;
    if (w.fetch) fetch(endpoint, { method: "POST", body: json, keepalive: true }).catch(function () {});
  };

  var randomId = function () {
    var bytes = new Uint8Array(8);
    (w.crypto || {}).getRandomValues ? crypto.getRandomValues(bytes) : bytes.forEach(function (_, i) { bytes[i] = Math.random() * 256; });
    return Array.prototype.map.call(bytes, function (b) { return (b + 256).toString(36).slice(-2); }).join("").slice(0, 12);
  };

  // Engaged time: visible and focused. Sent as a delta on every hide, so
  // the server adds them up per pageview.
  var notFound = attr("404") !== null;
  var pageUrl = "";
  var pageviewId = "";
  var engaged = 0;
  var activeSince = 0;
  var scrolled = 0;

  var active = function () {
    return d.visibilityState === "visible" && d.hasFocus();
  };
  var pause = function () {
    if (activeSince) engaged += Date.now() - activeSince;
    activeSince = 0;
  };
  var resume = function () {
    if (!activeSince && active()) activeSince = Date.now();
  };
  var flush = function () {
    pause();
    if (pageviewId && engaged >= 1000) {
      send("engagement", { i: pageviewId, e: engaged, d: scrolled });
      engaged = 0;
    }
  };
  var measureScroll = function () {
    var el = d.documentElement;
    var total = Math.max(el.scrollHeight, d.body ? d.body.scrollHeight : 0);
    var seen = (w.scrollY || el.scrollTop) + w.innerHeight;
    var depth = total > 0 ? Math.min(100, Math.round((seen / total) * 100)) : 100;
    if (depth > scrolled) scrolled = depth;
  };

  var currentUrl = function () {
    var l = location;
    return l.protocol + "//" + l.host + l.pathname + l.search + (useHash ? l.hash : "");
  };

  var pageview = function () {
    var url = currentUrl();
    if (url === pageUrl) return;
    var referrer = pageUrl || d.referrer;
    flush();
    pageUrl = url;
    pageviewId = randomId();
    engaged = 0;
    scrolled = 0;
    measureScroll();
    resume();
    send("pageview", {
      i: pageviewId,
      r: referrer,
      t: d.title,
      w: screen.width,
      h: screen.height,
      l: n.language,
    });
    if (notFound) track("404", { path: location.pathname });
    notFound = false;
  };

  var track = function (name, props) {
    if (typeof name !== "string" || !name) return;
    send("event", { i: pageviewId, n: name, p: props && typeof props === "object" ? props : undefined });
  };

  // Single page apps.
  var wrap = function (method) {
    var original = history[method];
    history[method] = function () {
      var result = original.apply(this, arguments);
      pageview();
      return result;
    };
  };
  wrap("pushState");
  wrap("replaceState");
  w.addEventListener("popstate", pageview);
  if (useHash) w.addEventListener("hashchange", pageview);

  d.addEventListener("visibilitychange", function () {
    d.visibilityState === "hidden" ? flush() : resume();
  });
  w.addEventListener("pagehide", flush);
  w.addEventListener("blur", pause);
  w.addEventListener("focus", resume);
  w.addEventListener("scroll", function () {
    measureScroll();
    resume();
  }, { passive: true });
  // A page can load without window focus; any input means someone is there.
  d.addEventListener("pointerdown", resume, true);
  d.addEventListener("keydown", resume, true);

  var downloads = /\.(pdf|zip|gz|tgz|dmg|pkg|exe|msi|apk|docx?|xlsx?|pptx?|csv|txt|rtf|epub|mp3|wav|mp4|mov|avi|mkv|psd|ai|svg|key|numbers|pages)$/i;

  d.addEventListener(
    "click",
    function (event) {
      var target = event.target;
      if (!target || !target.closest) return;

      var tagged = target.closest("[data-runlight]");
      if (tagged) {
        var props = {};
        for (var i = 0; i < tagged.attributes.length; i++) {
          var a = tagged.attributes[i];
          if (a.name.indexOf("data-runlight-") === 0) props[a.name.slice(14)] = a.value;
        }
        track(tagged.getAttribute("data-runlight"), props);
      }

      var link = target.closest("a[href]");
      if (!link || tagged) return;
      var href = link.href;
      if (!/^https?:/.test(href)) return;
      if (attr("downloads") !== "false" && downloads.test(link.pathname)) {
        track("File download", { url: href });
      } else if (attr("outbound") !== "false" && link.host !== location.host) {
        track("Outbound link", { url: href });
      }
    },
    true
  );

  w.runlight = track;
  pageview();
  for (var q = 0; q < queued.length; q++) track.apply(null, queued[q]);
})();
