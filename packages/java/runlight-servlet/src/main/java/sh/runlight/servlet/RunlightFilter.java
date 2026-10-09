package sh.runlight.servlet;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Pattern;
import sh.runlight.Runlight;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * Runlight's part of every request to the app, as a Jakarta Servlet {@link Filter} mapped to {@code
 * /*}: what the standalone server and the PHP port's front controller do before the routes.
 *
 * <ul>
 *   <li>A request on a link domain added in Settings (such as {@code t.example.com}) is answered
 *       there: {@code /{slug}} with its redirect, anything else with a 404, the dashboard's own
 *       paths left alone so its owner can always reach it.
 *   <li>A GET for {@code {linkPath}/{slug}} ({@code /go/{slug}} by default) on the app's own
 *       domain, within the web app's context, is answered with the short link's redirect.
 *   <li>Every other request goes down the chain, and a GET is then reported with {@link
 *       Runlight#observe(Request)}, which records it when it came from a known AI agent (they run
 *       no JavaScript, so the tracker never sees them) and ignores it otherwise.
 * </ul>
 *
 * <pre>{@code
 * FilterRegistration.Dynamic f = servletContext.addFilter("runlight", new RunlightFilter(rl));
 * f.addMappingForUrlPatterns(null, false, "/*");
 * }</pre>
 *
 * <p>It never reads the request's body, which stays the app's. A link domain wants the app at the
 * root context, since its slugs are read from the whole path.
 */
public final class RunlightFilter implements Filter {
  private final Runlight runlight;
  private final boolean observe;
  private final Pattern linkPath;

  /** Link domains, short links, and AI agent fetches. */
  public RunlightFilter(Runlight runlight) {
    this(runlight, true);
  }

  /** Link domains and short links, and AI agent fetches only when {@code observe} is true. */
  public RunlightFilter(Runlight runlight, boolean observe) {
    this.runlight = Objects.requireNonNull(runlight, "runlight");
    this.observe = observe;
    this.linkPath = Pattern.compile("^" + Pattern.quote(runlight.linkPath) + "/[^/]+/?\\z");
  }

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    if (!(request instanceof HttpServletRequest req)
        || !(response instanceof HttpServletResponse res)) {
      chain.doFilter(request, response);
      return;
    }
    Request ours = ServletBridge.request(req);
    Response answer = answer(req, ours);
    if (answer != null) {
      ServletBridge.send(res, answer, runlight);
      return;
    }
    try {
      chain.doFilter(request, response);
    } finally {
      if (observe && ours.method().equals("GET")) {
        runlight.observe(ours);
      }
    }
  }

  /** The link domain's or short link's answer, or null for a request the app answers. */
  private Response answer(HttpServletRequest req, Request request) {
    Map<String, Object> context = ServletBridge.context(req);
    try {
      Response linked = runlight.linkDomainResponse(request, context);
      if (linked != null) {
        return linked;
      }
      if (!request.method().equals("GET")) {
        return null;
      }
      Url url = new Url(request.url());
      String within = within(url.pathname, req.getContextPath());
      if (!linkPath.matcher(within).find()) {
        return null;
      }
      url.pathname = within;
      return runlight.linkHandler().apply(request.withUrl(url.href()));
    } catch (RuntimeException e) {
      ServletBridge.log(e);
      return ServletBridge.internalError();
    }
  }

  /** The path within the web app's context. */
  static String within(String path, String context) {
    if (context == null || context.isEmpty() || !path.startsWith(context)) {
      return path;
    }
    String rest = path.substring(context.length());
    return rest.isEmpty() ? "/" : rest;
  }

  @Override
  public String toString() {
    return "RunlightFilter[linkPath=" + runlight.linkPath + ", observe=" + observe + "]";
  }
}
