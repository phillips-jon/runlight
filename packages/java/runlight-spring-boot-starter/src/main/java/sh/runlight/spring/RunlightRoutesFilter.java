package sh.runlight.spring;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Objects;
import org.springframework.core.Ordered;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Request;
import sh.runlight.servlet.BodyTooLarge;
import sh.runlight.servlet.ServletBridge;

/**
 * Runlight's routes on a Spring MVC app: a filter, which Spring Boot registers for every request,
 * that answers those under its path (the dashboard and its assets, the tracker, the API, MCP, and
 * accounts) and passes the rest down the chain. A filter rather than a servlet, so it sits ahead of
 * the app's own handlers and of Spring Security's chain, since the routes have their own token.
 */
public final class RunlightRoutesFilter implements Filter, Ordered {
  private final Runlight runlight;
  private final Routes routes;
  private final String path;
  private final int order;

  /** {@code routes} answering under {@code path} within the app's context, at this order. */
  public RunlightRoutesFilter(Runlight runlight, Routes routes, String path, int order) {
    this.runlight = Objects.requireNonNull(runlight, "runlight");
    this.routes = Objects.requireNonNull(routes, "routes");
    this.path = Routes.normaliseBase(Objects.requireNonNull(path, "path"));
    this.order = order;
  }

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    if (!(request instanceof HttpServletRequest req)
        || !(response instanceof HttpServletResponse res)) {
      chain.doFilter(request, response);
      return;
    }
    String context = req.getContextPath() == null ? "" : req.getContextPath();
    String uri = req.getRequestURI() == null ? "/" : req.getRequestURI();
    String within = uri.startsWith(context) ? uri.substring(context.length()) : uri;
    if (!path.isEmpty() && !within.equals(path) && !within.startsWith(path + "/")) {
      chain.doFilter(request, response);
      return;
    }
    Request ours;
    try {
      ours = ServletBridge.requestWithBody(req);
    } catch (BodyTooLarge e) {
      ServletBridge.tooLarge(res);
      return;
    }
    ServletBridge.send(res, routes.handle(ours, ServletBridge.context(req)), runlight);
  }

  /** The path it answers under, within the context. */
  public String path() {
    return path;
  }

  @Override
  public int getOrder() {
    return order;
  }

  @Override
  public String toString() {
    return "RunlightRoutesFilter[path=" + path + ", order=" + order + "]";
  }
}
