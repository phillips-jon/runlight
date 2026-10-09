package sh.runlight;

/** Refused before anything was fetched, because the address is not on the public internet. */
public final class PrivateAddressError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  public PrivateAddressError(String what) {
    super(what + " is not a public address");
  }
}
