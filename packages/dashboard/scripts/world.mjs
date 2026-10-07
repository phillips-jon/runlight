// The world map's shapes, projected once at build time so the dashboard
// ships plain SVG paths keyed by country code and needs no map library.
// Natural Earth 1:110m (public domain) through world-atlas, Equal Earth.
import { geoEqualEarth, geoPath } from "d3-geo";
import countries from "i18n-iso-countries";
import { createRequire } from "node:module";
import { feature } from "topojson-client";

const require = createRequire(import.meta.url);
export const WIDTH = 960;
export const HEIGHT = 470;

export function world() {
  const topo = require("world-atlas/countries-110m.json");
  const land = feature(topo, topo.objects.countries);
  // Antarctica takes a fifth of the map and gets no visitors.
  land.features = land.features.filter((f) => f.id !== "010");
  const projection = geoEqualEarth().fitExtent([[4, 4], [WIDTH - 4, HEIGHT - 4]], land);
  const path = geoPath(projection).digits(1);
  const shapes = land.features
    .map((f) => ({ id: f.id ? countries.numericToAlpha2(f.id) ?? "" : "", d: path(f) ?? "" }))
    .filter((s) => s.d);
  return JSON.stringify({ w: WIDTH, h: HEIGHT, shapes });
}
