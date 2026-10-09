package sh.runlight.servlet;

import jakarta.servlet.ServletRegistration;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletMapping;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.MappingMatch;
import java.io.IOException;
import java.util.Objects;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Request;

/**
 * Runlight's routes (the dashboard and its assets, the tracker, the API, MCP, and accounts) as a
 * Jakarta {@link HttpServlet}, answering every request under its mapping. Every method is answered
 * by the routes, so a {@code HEAD} or {@code OPTIONS} gets Runlight's answer rather than the
 * container's own.
 *
 * <pre>{@code
 * ServletRegistration.Dynamic s = servletContext.addServlet("runlight", new RunlightServlet(rl));
 * s.addMapping("/runlight/*");
 * }</pre>
 *
 * <p>Built with {@link Runlight} alone, or with {@link Routes.Options} whose {@code basePath} is
 * unset, the routes' base path is found from the mapping: the context path and the mapping's prefix
 * ({@code /runlight} for {@code /runlight/*}). Pair it with {@link RunlightFilter} on {@code /*}
 * for short links, link domains, and AI agent fetches.
 */
public final class RunlightServlet extends HttpServlet {
  private static final long serialVersionUID = 1L;

  private final transient Runlight runlight;
  private final transient Routes.Options options;
  private transient volatile Routes routes;

  /** The routes with their default options, the base path from the mapping. */
  public RunlightServlet(Runlight runlight) {
    this(runlight, new Routes.Options());
  }

  /**
   * The routes with these options (the token, authorize, accounts, and so on). An unset basePath is
   * filled in from the mapping when the servlet starts.
   */
  public RunlightServlet(Runlight runlight, Routes.Options options) {
    this.runlight = Objects.requireNonNull(runlight, "runlight");
    this.options = Objects.requireNonNull(options, "options");
  }

  /** Routes the app made itself, with their own base path. */
  public RunlightServlet(Runlight runlight, Routes routes) {
    this.runlight = Objects.requireNonNull(runlight, "runlight");
    this.options = null;
    this.routes = Objects.requireNonNull(routes, "routes");
  }

  /** The routes it serves; null until it starts or answers its first request. */
  public Routes routes() {
    return routes;
  }

  @Override
  public void init() {
    if (routes != null) {
      return;
    }
    if (options.basePath != null) {
      build(null);
      return;
    }
    ServletRegistration registration = getServletContext().getServletRegistration(getServletName());
    if (registration == null) {
      return;
    }
    String context = getServletContext().getContextPath();
    for (String mapping : registration.getMappings()) {
      if (mapping.equals("/*") || mapping.equals("/")) {
        build(context.isEmpty() ? "/" : context);
        return;
      }
      if (mapping.startsWith("/") && mapping.endsWith("/*")) {
        build(context + mapping.substring(0, mapping.length() - 2));
        return;
      }
    }
  }

  private synchronized Routes build(String base) {
    if (routes == null) {
      if (base != null && options.basePath == null) {
        options.basePath = base;
      }
      routes = runlight.routes(options);
    }
    return routes;
  }

  /** The routes, made from the request's mapping when the start could not tell it. */
  private Routes routes(HttpServletRequest req) {
    Routes made = routes;
    if (made != null) {
      return made;
    }
    String context = req.getContextPath() == null ? "" : req.getContextPath();
    HttpServletMapping mapping = req.getHttpServletMapping();
    boolean prefix = mapping != null && mapping.getMappingMatch() == MappingMatch.PATH;
    String base = prefix ? context + req.getServletPath() : context;
    return build(base.isEmpty() ? "/" : base);
  }

  @Override
  protected void service(HttpServletRequest req, HttpServletResponse res) {
    Routes served = routes(req);
    Request request;
    try {
      request = ServletBridge.requestWithBody(req);
    } catch (BodyTooLarge e) {
      ServletBridge.tooLarge(res);
      return;
    } catch (IOException e) {
      // The client went away while sending.
      return;
    }
    ServletBridge.send(res, served.handle(request, ServletBridge.context(req)), runlight);
  }

  @Override
  public String toString() {
    Routes made = routes;
    return "RunlightServlet[" + (made == null ? "not started" : "started") + "]";
  }
}
