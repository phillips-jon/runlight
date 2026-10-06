export interface Location {
  /** ISO 3166-1 alpha-2, upper case. */
  country: string;
  /** ISO 3166-2, such as "US-CA". */
  region: string;
  city: string;
}

/** Looks a client IP up in a database of the app's choosing, such as an MMDB file. */
export type GeoLookup = (ip: string) => Partial<Location> | null | Promise<Partial<Location> | null>;

const EMPTY: Location = { country: "", region: "", city: "" };

function decode(value: string | null): string {
  if (!value) return "";
  try {
    return decodeURIComponent(value).trim();
  } catch {
    return value.trim();
  }
}

function clean(location: Partial<Location>): Location {
  let country = (location.country ?? "").toUpperCase().slice(0, 2);
  if (!/^[A-Z]{2}$/.test(country) || country === "XX" || country === "T1") country = "";
  let region = (location.region ?? "").toUpperCase().slice(0, 10);
  if (region && !region.includes("-") && country) region = `${country}-${region}`;
  if (!country) region = "";
  const city = country ? (location.city ?? "").slice(0, 100) : "";
  return { country, region, city };
}

/** Location from the headers a hosting platform adds, if any. */
export function locationFromHeaders(headers: Headers): Location | null {
  const vercel = headers.get("x-vercel-ip-country");
  if (vercel) {
    return clean({
      country: vercel,
      region: decode(headers.get("x-vercel-ip-country-region")),
      city: decode(headers.get("x-vercel-ip-city")),
    });
  }
  const cloudflare = headers.get("cf-ipcountry");
  if (cloudflare) {
    return clean({
      country: cloudflare,
      region: decode(headers.get("cf-region-code")),
      city: decode(headers.get("cf-ipcity")),
    });
  }
  const netlify = headers.get("x-nf-geo");
  if (netlify) {
    try {
      const geo = JSON.parse(atob(netlify)) as { city?: string; country?: { code?: string }; subdivision?: { code?: string } };
      return clean({ country: geo.country?.code ?? "", region: geo.subdivision?.code ?? "", city: geo.city ?? "" });
    } catch {
      return null;
    }
  }
  return null;
}

export async function locate(headers: Headers, ip: string, lookup?: GeoLookup): Promise<Location> {
  const fromHeaders = locationFromHeaders(headers);
  if (fromHeaders?.country) return fromHeaders;
  if (lookup && ip) {
    try {
      const found = await lookup(ip);
      if (found) return clean(found);
    } catch {
      // A broken lookup must never lose the event.
    }
  }
  return EMPTY;
}
