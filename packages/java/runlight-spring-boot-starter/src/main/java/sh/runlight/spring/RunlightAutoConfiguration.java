package sh.runlight.spring;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import javax.sql.DataSource;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import sh.runlight.Runlight;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Runlight as a bean, from {@code runlight.*} properties: its tables in the database {@code
 * runlight.database-url} names, else in the app's own {@link DataSource}; an app's own {@link
 * SqlStore} bean wins over both, and its own {@link Runlight} bean replaces this one. The scheduled
 * check runs every {@code runlight.check.every} (a minute) while the context runs. {@code
 * runlight.enabled=false} turns the starter off.
 */
@AutoConfiguration(
    afterName = {
      "org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration",
      "org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration"
    })
@ConditionalOnProperty(prefix = "runlight", name = "enabled", matchIfMissing = true)
@EnableConfigurationProperties(RunlightProperties.class)
public class RunlightAutoConfiguration {
  /** Made by Spring. */
  public RunlightAutoConfiguration() {}

  /**
   * Runlight's tables: in the database {@code runlight.database-url} names, else in the app's one
   * DataSource (unwrapped from Spring's transaction-aware proxy, so a write never joins the app's
   * transaction). Closed when the context closes; a DataSource's pool is the app's and stays open.
   */
  @Bean
  @ConditionalOnMissingBean
  public SqlStore runlightStore(
      RunlightProperties properties, ObjectProvider<DataSource> dataSources) {
    String url = properties.getDatabaseUrl();
    if (url != null && !url.isBlank()) {
      return Stores.url(url.strip());
    }
    DataSource dataSource = dataSources.getIfUnique();
    if (dataSource == null) {
      throw new IllegalStateException(
          "Runlight: set runlight.database-url, or give the app one DataSource bean");
    }
    return Stores.dataSource(plain(dataSource));
  }

  /** Runlight, from the properties and the store. */
  @Bean
  @ConditionalOnMissingBean
  public Runlight runlight(RunlightProperties properties, SqlStore store) {
    return new Runlight(options(properties, store));
  }

  /** The options {@code runlight.*} gives. */
  static Runlight.Options options(RunlightProperties properties, SqlStore store) {
    Runlight.Options options = new Runlight.Options().store(store);
    if (!properties.getSites().isEmpty()) {
      List<Map<String, Object>> sites = new ArrayList<>();
      for (RunlightProperties.Site site : properties.getSites()) {
        sites.add(site.toMap());
      }
      options.sites(sites);
    } else if (properties.getSite() != null) {
      options.site(properties.getSite().toMap());
    }
    options.managedSites(properties.isManagedSites());
    if (properties.getSecret() != null && !properties.getSecret().isBlank()) {
      options.secret(properties.getSecret());
    }
    if (properties.getLinkPath() != null) {
      options.linkPath(properties.getLinkPath());
    }
    // Left unset, Runlight's own default applies, so it can warn when nothing sits in front.
    if (properties.getTrustProxy() != null) {
      options.trustProxy(trustProxy(properties.getTrustProxy()));
    }
    if (properties.getRateLimit() != null) {
      int limit = properties.getRateLimit();
      if (limit <= 0) {
        options.rateLimit(false);
      } else {
        options.rateLimit((long) limit);
      }
    }
    return options;
  }

  /** {@code true}, {@code false}, or the one header named. */
  static Object trustProxy(String value) {
    String text = value == null ? "" : value.strip().toLowerCase(Locale.ROOT);
    if (text.isEmpty() || text.equals("true")) {
      return true;
    }
    if (text.equals("false")) {
      return false;
    }
    return text;
  }

  /**
   * The {@code DataSource} underneath Spring's {@code TransactionAwareDataSourceProxy}, which would
   * hand the store the connection of a transaction the app has open, so a visit would vanish with
   * the rollback the app made. Found by name, since spring-jdbc is the app's.
   */
  static DataSource plain(DataSource dataSource) {
    DataSource ds = dataSource;
    for (int depth = 0; depth < 8; depth++) {
      if (!ds.getClass()
          .getName()
          .equals("org.springframework.jdbc.datasource.TransactionAwareDataSourceProxy")) {
        return ds;
      }
      try {
        Method target = ds.getClass().getMethod("getTargetDataSource");
        if (!(target.invoke(ds) instanceof DataSource inner)) {
          return ds;
        }
        ds = inner;
      } catch (ReflectiveOperationException | RuntimeException e) {
        return ds;
      }
    }
    return ds;
  }

  /** The scheduled check, unless {@code runlight.check.enabled=false}. */
  @Configuration(proxyBeanMethods = false)
  @ConditionalOnProperty(
      prefix = "runlight.check",
      name = "enabled",
      havingValue = "true",
      matchIfMissing = true)
  static class Check {
    @Bean
    RunlightChecker runlightChecker(Runlight runlight, RunlightProperties properties) {
      return new RunlightChecker(runlight, properties.getCheck().getEvery());
    }
  }
}
