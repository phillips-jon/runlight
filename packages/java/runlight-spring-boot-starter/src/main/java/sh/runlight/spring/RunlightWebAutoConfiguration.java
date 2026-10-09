package sh.runlight.spring;

import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;
import sh.runlight.Routes;
import sh.runlight.Runlight;

/**
 * Runlight on the app's own Spring MVC server: the routes at {@code runlight.base-path} ({@code
 * /runlight}) within the app's context, and the link filter for link domains, short links at {@code
 * runlight.link-path} ({@code /go}), and AI agent fetches ({@code runlight.observe}). Both are
 * filters Spring Boot maps to every request, ahead of Spring Security's chain (the routes behind it
 * when served open, {@code runlight.open}, so the app's auth guards them), at {@code
 * runlight.web.order}. A {@link Routes} bean of the app's own replaces the one made here; {@code
 * runlight.web.enabled=false} turns both off.
 */
@AutoConfiguration(after = RunlightAutoConfiguration.class)
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@ConditionalOnClass(name = "jakarta.servlet.Filter")
@ConditionalOnBean(Runlight.class)
@ConditionalOnProperty(prefix = "runlight.web", name = "enabled", matchIfMissing = true)
public class RunlightWebAutoConfiguration {
  /** Made by Spring. */
  public RunlightWebAutoConfiguration() {}

  /**
   * The routes: the token from {@code runlight.token}, else {@code RUNLIGHT_TOKEN}, or none with
   * {@code runlight.open}; the base path is the app's context path and {@code runlight.base-path}.
   */
  @Bean
  @ConditionalOnMissingBean
  public Routes runlightRoutes(
      Runlight runlight, RunlightProperties properties, Environment environment) {
    Routes.Options options = new Routes.Options();
    options.basePath(contextPath(environment) + Routes.normaliseBase(properties.getBasePath()));
    if (properties.isOpen()) {
      options.token(null);
    } else if (properties.getToken() != null && !properties.getToken().isBlank()) {
      options.token(properties.getToken());
    }
    if (properties.getOrigin() != null && !properties.getOrigin().isBlank()) {
      options.origin(properties.getOrigin());
    }
    if (properties.isAccounts()) {
      options.accounts(true);
    }
    if (properties.getCronSecret() != null && !properties.getCronSecret().isBlank()) {
      options.cronSecret(properties.getCronSecret());
    }
    if (properties.getObserveKey() != null && !properties.getObserveKey().isBlank()) {
      options.observeKey(properties.getObserveKey());
    }
    return runlight.routes(options);
  }

  /** The routes' filter. */
  @Bean
  @ConditionalOnMissingBean
  public RunlightRoutesFilter runlightRoutesFilter(
      Runlight runlight, Routes routes, RunlightProperties properties) {
    Integer order = properties.getWeb().getOrder();
    int at =
        order != null
            ? order
            : properties.isOpen()
                ? RunlightProperties.OPEN_ORDER
                : RunlightProperties.DEFAULT_ORDER;
    return new RunlightRoutesFilter(runlight, routes, properties.getBasePath(), at);
  }

  /** The link filter. */
  @Bean
  @ConditionalOnMissingBean
  public RunlightLinksFilter runlightLinksFilter(Runlight runlight, RunlightProperties properties) {
    Integer order = properties.getWeb().getOrder();
    return new RunlightLinksFilter(
        runlight, properties.isObserve(), order != null ? order : RunlightProperties.DEFAULT_ORDER);
  }

  /** The app's servlet context path, such as {@code /app}, or empty. */
  static String contextPath(Environment environment) {
    String path = environment.getProperty("server.servlet.context-path", "");
    return Routes.normaliseBase(path);
  }
}
