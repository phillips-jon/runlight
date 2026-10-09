package sh.runlight.spring;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import java.io.IOException;
import org.springframework.core.Ordered;
import sh.runlight.Runlight;
import sh.runlight.servlet.RunlightFilter;

/**
 * {@link RunlightFilter} on a Spring MVC app, as a bean with an order: link domains and short links
 * on the app's own link path answered, and the app's pages fetched by AI agents recorded. Ahead of
 * Spring Security's chain, so a short link needs no sign-in.
 */
public final class RunlightLinksFilter implements Filter, Ordered {
  private final RunlightFilter filter;
  private final int order;

  /** Link domains, short links, and AI agent fetches when {@code observe}, at this order. */
  public RunlightLinksFilter(Runlight runlight, boolean observe, int order) {
    this.filter = new RunlightFilter(runlight, observe);
    this.order = order;
  }

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    filter.doFilter(request, response, chain);
  }

  @Override
  public int getOrder() {
    return order;
  }

  @Override
  public String toString() {
    return "RunlightLinksFilter[" + filter + ", order=" + order + "]";
  }
}
