package sh.runlight.spring;

import java.time.Duration;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import org.springframework.context.SmartLifecycle;
import sh.runlight.Runlight;

/**
 * Runlight's scheduled upkeep, {@link Runlight#check()}, from when the context has started until it
 * stops: the first a second after the start, then every {@code runlight.check.every} (a minute by
 * default), on a virtual thread of its own. It rotates salts, sends the email reports that are due,
 * deletes visits past each site's retention, and builds the daily rollups; it is safe on every
 * instance of the app at once.
 */
public final class RunlightChecker implements SmartLifecycle {
  private static final System.Logger LOGGER = System.getLogger("sh.runlight.spring");

  /** The shortest interval between checks. */
  private static final Duration SHORTEST = Duration.ofSeconds(1);

  private final Runlight runlight;
  private final Duration every;

  private final ReentrantLock lock = new ReentrantLock();
  private final Condition wake = lock.newCondition();
  private boolean running;
  private Thread loop;

  /** The first check's delay after the start; the tests shorten it. */
  volatile Duration firstDelay = Duration.ofSeconds(1);

  /** How long {@link #stop} waits for a check under way. */
  volatile Duration stopWait = Duration.ofSeconds(30);

  /** Checks every {@code every}, at least a second apart. */
  public RunlightChecker(Runlight runlight, Duration every) {
    this.runlight = runlight;
    this.every = every == null || every.compareTo(SHORTEST) < 0 ? SHORTEST : every;
  }

  @Override
  public void start() {
    lock.lock();
    try {
      if (running) {
        return;
      }
      running = true;
      loop = Thread.ofVirtual().name("runlight-check").unstarted(this::loop);
      loop.start();
    } finally {
      lock.unlock();
    }
  }

  private void loop() {
    long wait = firstDelay.toNanos();
    while (true) {
      lock.lock();
      try {
        long left = wait;
        while (running && left > 0) {
          left = wake.awaitNanos(left);
        }
        if (!running) {
          return;
        }
      } catch (InterruptedException e) {
        return;
      } finally {
        lock.unlock();
      }
      check();
      wait = every.toNanos();
    }
  }

  /** One check; a failure is logged and the next one runs on time. */
  void check() {
    try {
      runlight.check();
    } catch (RuntimeException e) {
      LOGGER.log(System.Logger.Level.ERROR, "Runlight: the scheduled check failed", e);
    }
  }

  /** Stops the interval and waits for a check under way to end. */
  @Override
  public void stop() {
    Thread thread;
    lock.lock();
    try {
      running = false;
      wake.signalAll();
      thread = loop;
      loop = null;
    } finally {
      lock.unlock();
    }
    if (thread == null || thread.equals(Thread.currentThread())) {
      return;
    }
    try {
      thread.join(stopWait);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }

  @Override
  public boolean isRunning() {
    lock.lock();
    try {
      return running;
    } finally {
      lock.unlock();
    }
  }

  @Override
  public String toString() {
    return "RunlightChecker[every=" + every + "]";
  }
}
