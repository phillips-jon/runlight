package sh.runlight.spring;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Runlight's settings, {@code runlight.*}. Each is optional.
 *
 * <pre>
 * # the database: a URL, else the app's own DataSource
 * runlight.database-url=sqlite:./data/runlight.db
 * # the site this app counts (or runlight.sites[0].*, or runlight.managed-sites=true)
 * runlight.site.name=example.com
 * runlight.site.hostnames=example.com
 * runlight.site.timezone=Europe/London
 * runlight.token=${RUNLIGHT_TOKEN}
 * runlight.secret=${RUNLIGHT_SECRET}
 * # where the dashboard and API are, within the app's context
 * runlight.base-path=/runlight
 * # where short links on the app's own domain are
 * runlight.link-path=/go
 * runlight.check.every=1m
 * </pre>
 */
@ConfigurationProperties(prefix = "runlight")
public class RunlightProperties {
  /** Ahead of Spring Security's filter chain, whose order is -100. */
  public static final int DEFAULT_ORDER = -110;

  /**
   * Behind Spring Security's filter chain: the order of a dashboard served {@link #isOpen() open},
   * which has no token of its own and is left to the app's auth.
   */
  public static final int OPEN_ORDER = -90;

  private boolean enabled = true;
  private String databaseUrl;
  private Site site = new Site();
  private List<Site> sites = new ArrayList<>();
  private boolean managedSites;
  private String token;
  private boolean open;
  private String secret;
  private String basePath = "/runlight";
  private String linkPath = "/go";
  private String trustProxy;
  private Integer rateLimit;
  private String origin;
  private boolean accounts;
  private String cronSecret;
  private String observeKey;
  private boolean observe = true;
  private final Check check = new Check();
  private final Web web = new Web();

  /** Made by Spring. */
  public RunlightProperties() {}

  /** One site: {@code id}, {@code name}, {@code hostnames}, and {@code timezone}. */
  public static class Site {
    private String id;
    private String name;
    private List<String> hostnames;
    private String timezone;

    /** Made by Spring. */
    public Site() {}

    /** A stable id stored with every row. Default {@code default}. */
    public String getId() {
      return id;
    }

    /** Sets {@link #getId()}. */
    public void setId(String id) {
      this.id = id;
    }

    /** The name the dashboard shows. */
    public String getName() {
      return name;
    }

    /** Sets {@link #getName()}. */
    public void setName(String name) {
      this.name = name;
    }

    /**
     * The hostnames that belong to the site, without www. With one site, none means any hostname;
     * with several, each site needs at least one.
     */
    public List<String> getHostnames() {
      return hostnames;
    }

    /** Sets {@link #getHostnames()}. */
    public void setHostnames(List<String> hostnames) {
      this.hostnames = hostnames;
    }

    /** An IANA timezone for reports, such as {@code Europe/London}. Default UTC. */
    public String getTimezone() {
      return timezone;
    }

    /** Sets {@link #getTimezone()}. */
    public void setTimezone(String timezone) {
      this.timezone = timezone;
    }

    /** The site as Runlight takes it, with only the keys set. */
    Map<String, Object> toMap() {
      Map<String, Object> map = new LinkedHashMap<>();
      if (id != null) {
        map.put("id", id);
      }
      if (name != null) {
        map.put("name", name);
      }
      if (hostnames != null) {
        map.put("hostnames", new ArrayList<Object>(hostnames));
      }
      if (timezone != null) {
        map.put("timezone", timezone);
      }
      return map;
    }
  }

  /** The scheduled check, {@code runlight.check.*}. */
  public static class Check {
    private boolean enabled = true;
    private Duration every = Duration.ofMinutes(1);

    /** Made by Spring. */
    public Check() {}

    /** Whether the starter runs {@code check()} on its own schedule. */
    public boolean isEnabled() {
      return enabled;
    }

    /** Sets {@link #isEnabled()}. */
    public void setEnabled(boolean enabled) {
      this.enabled = enabled;
    }

    /** How often. Default a minute. */
    public Duration getEvery() {
      return every;
    }

    /** Sets {@link #getEvery()}. */
    public void setEvery(Duration every) {
      this.every = every;
    }
  }

  /** The filters on Spring MVC, {@code runlight.web.*}. */
  public static class Web {
    private boolean enabled = true;
    private Integer order;

    /** Made by Spring. */
    public Web() {}

    /** Whether the routes and the link filter are served. */
    public boolean isEnabled() {
      return enabled;
    }

    /** Sets {@link #isEnabled()}. */
    public void setEnabled(boolean enabled) {
      this.enabled = enabled;
    }

    /**
     * The filters' order: {@link #DEFAULT_ORDER}, ahead of Spring Security's chain, else {@link
     * #OPEN_ORDER} for the routes when they are served open.
     */
    public Integer getOrder() {
      return order;
    }

    /** Sets {@link #getOrder()}. */
    public void setOrder(Integer order) {
      this.order = order;
    }
  }

  /** Whether the starter makes Runlight at all. */
  public boolean isEnabled() {
    return enabled;
  }

  /** Sets {@link #isEnabled()}. */
  public void setEnabled(boolean enabled) {
    this.enabled = enabled;
  }

  /**
   * The database, as the standalone server's DATABASE_URL names it: {@code postgres://} or {@code
   * postgresql://}, {@code mysql://} or {@code mariadb://}, or {@code sqlite:} or {@code file:} and
   * a path. Unset, Runlight keeps its tables in the app's own DataSource.
   */
  public String getDatabaseUrl() {
    return databaseUrl;
  }

  /** Sets {@link #getDatabaseUrl()}. */
  public void setDatabaseUrl(String databaseUrl) {
    this.databaseUrl = databaseUrl;
  }

  /** The site this app counts. Ignored when {@link #getSites()} names any. */
  public Site getSite() {
    return site;
  }

  /** Sets {@link #getSite()}. */
  public void setSite(Site site) {
    this.site = site;
  }

  /** Several sites in one install, told apart by hostname. */
  public List<Site> getSites() {
    return sites;
  }

  /** Sets {@link #getSites()}. */
  public void setSites(List<Site> sites) {
    this.sites = sites;
  }

  /** Whether sites are added and changed in the dashboard and kept in the database. */
  public boolean isManagedSites() {
    return managedSites;
  }

  /** Sets {@link #isManagedSites()}. */
  public void setManagedSites(boolean managedSites) {
    this.managedSites = managedSites;
  }

  /** The token the dashboard and API ask for. Default {@code $RUNLIGHT_TOKEN}. */
  public String getToken() {
    return token;
  }

  /** Sets {@link #getToken()}. */
  public void setToken(String token) {
    this.token = token;
  }

  /**
   * Whether the dashboard and API are served with no token, behind the app's own auth. They are
   * then ordered behind Spring Security's chain.
   */
  public boolean isOpen() {
    return open;
  }

  /** Sets {@link #isOpen()}. */
  public void setOpen(boolean open) {
    this.open = open;
  }

  /** Encrypts the keys kept in the database. Default {@code $RUNLIGHT_SECRET}, then the token. */
  public String getSecret() {
    return secret;
  }

  /** Sets {@link #getSecret()}. */
  public void setSecret(String secret) {
    this.secret = secret;
  }

  /** Where the dashboard and API are, within the app's context path. */
  public String getBasePath() {
    return basePath;
  }

  /** Sets {@link #getBasePath()}. */
  public void setBasePath(String basePath) {
    this.basePath = basePath;
  }

  /** Where short links on the app's own domain are, within its context path. */
  public String getLinkPath() {
    return linkPath;
  }

  /** Sets {@link #getLinkPath()}. */
  public void setLinkPath(String linkPath) {
    this.linkPath = linkPath;
  }

  /**
   * {@code true}, {@code false}, or the one header to read the client's address from ({@code
   * x-forwarded-for}, {@code x-real-ip}, or {@code cf-connecting-ip}). Unset acts as {@code true},
   * and Runlight warns once if requests then arrive straight from public addresses.
   */
  public String getTrustProxy() {
    return trustProxy;
  }

  /** Sets {@link #getTrustProxy()}. */
  public void setTrustProxy(String trustProxy) {
    this.trustProxy = trustProxy;
  }

  /** Tracker requests allowed per visitor address per minute; 0 turns the limit off. */
  public Integer getRateLimit() {
    return rateLimit;
  }

  /** Sets {@link #getRateLimit()}. */
  public void setRateLimit(Integer rateLimit) {
    this.rateLimit = rateLimit;
  }

  /** The address people open the app at, such as {@code https://example.com}. */
  public String getOrigin() {
    return origin;
  }

  /** Sets {@link #getOrigin()}. */
  public void setOrigin(String origin) {
    this.origin = origin;
  }

  /** Whether the dashboard has sign-in accounts. */
  public boolean isAccounts() {
    return accounts;
  }

  /** Sets {@link #isAccounts()}. */
  public void setAccounts(boolean accounts) {
    this.accounts = accounts;
  }

  /** Also accepted as a bearer token on POST /api/check. Default {@code $CRON_SECRET}. */
  public String getCronSecret() {
    return cronSecret;
  }

  /** Sets {@link #getCronSecret()}. */
  public void setCronSecret(String cronSecret) {
    this.cronSecret = cronSecret;
  }

  /**
   * Lets another site report AI agent fetches to POST /api/observe. Default {@code
   * $RUNLIGHT_OBSERVE_KEY}.
   */
  public String getObserveKey() {
    return observeKey;
  }

  /** Sets {@link #getObserveKey()}. */
  public void setObserveKey(String observeKey) {
    this.observeKey = observeKey;
  }

  /** Whether the app's own pages fetched by AI agents are recorded. */
  public boolean isObserve() {
    return observe;
  }

  /** Sets {@link #isObserve()}. */
  public void setObserve(boolean observe) {
    this.observe = observe;
  }

  /** The scheduled check. */
  public Check getCheck() {
    return check;
  }

  /** The filters on Spring MVC. */
  public Web getWeb() {
    return web;
  }

  /** The secrets are never printed. */
  @Override
  public String toString() {
    return "RunlightProperties[basePath=" + basePath + ", linkPath=" + linkPath + "]";
  }
}
