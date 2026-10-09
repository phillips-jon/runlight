package sh.runlight.accounts;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import sh.runlight.Js;
import sh.runlight.http.Request;
import sh.runlight.store.SqlStore;

/**
 * The little of a Runlight that accounts on the web reach for: its store, its mail, and the
 * client's address. Mail is kept in a list instead of sent; {@code mailFails} makes sending throw.
 */
final class StandIn implements Web.Host {
  final List<Map<String, Object>> sent = new ArrayList<>();
  Map<String, Object> mail;
  RuntimeException mailFails;
  private final SqlStore store;
  private final List<Runnable> later = new ArrayList<>();

  StandIn(SqlStore store) {
    this.store = store;
  }

  /**
   * Work Runlight runs after the answer; idle() runs it, as an adapter does once the answer is out.
   */
  @Override
  public void later(Runnable work) {
    later.add(work);
  }

  void idle() {
    while (!later.isEmpty()) {
      later.remove(0).run();
    }
  }

  @Override
  public SqlStore store() {
    return store;
  }

  @Override
  public Map<String, Object> mailSettings() {
    return mail;
  }

  @Override
  public void sendMail(Map<String, Object> message) {
    if (mailFails != null) {
      throw mailFails;
    }
    sent.add(message);
  }

  /**
   * The last X-Forwarded-For entry, else the connection's address, as Runlight reads it by default.
   */
  @Override
  public String clientIp(Request request, Map<String, Object> context) {
    String header = request.headers().get("x-forwarded-for");
    if (header != null && !Js.trim(header).isEmpty()) {
      String last = "";
      for (String part : header.split(",", -1)) {
        if (!Js.trim(part).isEmpty()) {
          last = Js.trim(part);
        }
      }
      return last;
    }
    return context.get("ip") instanceof String ip ? ip : "";
  }
}
