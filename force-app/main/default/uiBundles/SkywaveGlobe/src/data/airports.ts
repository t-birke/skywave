/**
 * Static geography for the Skywave route network — IATA → coordinates/city.
 *
 * Mirrors `Skywave_Airports.ALL` (Apex) and
 * `scripts/apex/seedSkywaveRouteNetwork.apex`. Embedded here because the
 * UIBundle data SDK only exposes graphql/fetch — it can't invoke the
 * `@AuraEnabled` getAirportGeo() the LWC monitor uses. Keep in sync if the
 * network changes.
 */
export interface Airport {
  code: string;
  city: string;
  lat: number;
  lon: number;
}

export const AIRPORTS: Record<string, Airport> = {
  JFK: { code: 'JFK', city: 'New York', lat: 40.64, lon: -73.78 },
  LAX: { code: 'LAX', city: 'Los Angeles', lat: 33.94, lon: -118.41 },
  ORD: { code: 'ORD', city: 'Chicago', lat: 41.98, lon: -87.9 },
  SFO: { code: 'SFO', city: 'San Francisco', lat: 37.62, lon: -122.38 },
  DFW: { code: 'DFW', city: 'Dallas', lat: 32.9, lon: -97.04 },
  ATL: { code: 'ATL', city: 'Atlanta', lat: 33.64, lon: -84.43 },
  SEA: { code: 'SEA', city: 'Seattle', lat: 47.45, lon: -122.31 },
  MIA: { code: 'MIA', city: 'Miami', lat: 25.8, lon: -80.29 },
  BOS: { code: 'BOS', city: 'Boston', lat: 42.36, lon: -71.01 },
  DEN: { code: 'DEN', city: 'Denver', lat: 39.86, lon: -104.67 },
  IAD: { code: 'IAD', city: 'Washington', lat: 38.95, lon: -77.46 },
  YYZ: { code: 'YYZ', city: 'Toronto', lat: 43.68, lon: -79.63 },
  PHX: { code: 'PHX', city: 'Phoenix', lat: 33.43, lon: -112.01 },
  LHR: { code: 'LHR', city: 'London', lat: 51.47, lon: -0.45 },
  CDG: { code: 'CDG', city: 'Paris', lat: 49.01, lon: 2.55 },
  FCO: { code: 'FCO', city: 'Rome', lat: 41.8, lon: 12.25 },
  MUC: { code: 'MUC', city: 'Munich', lat: 48.35, lon: 11.79 },
  HND: { code: 'HND', city: 'Tokyo', lat: 35.55, lon: 139.78 },
  BKK: { code: 'BKK', city: 'Bangkok', lat: 13.69, lon: 100.75 },
  SIN: { code: 'SIN', city: 'Singapore', lat: 1.36, lon: 103.99 },
  CPT: { code: 'CPT', city: 'Cape Town', lat: -33.97, lon: 18.6 },
  RAK: { code: 'RAK', city: 'Marrakesh', lat: 31.61, lon: -8.04 },
  NBO: { code: 'NBO', city: 'Nairobi', lat: -1.32, lon: 36.93 },
  GIG: { code: 'GIG', city: 'Rio de Janeiro', lat: -22.81, lon: -43.25 },
  MEX: { code: 'MEX', city: 'Mexico City', lat: 19.44, lon: -99.07 },
  EZE: { code: 'EZE', city: 'Buenos Aires', lat: -34.82, lon: -58.54 },
  SYD: { code: 'SYD', city: 'Sydney', lat: -33.95, lon: 151.18 },
  AKL: { code: 'AKL', city: 'Auckland', lat: -37.01, lon: 174.79 },
  DXB: { code: 'DXB', city: 'Dubai', lat: 25.25, lon: 55.36 },
  IST: { code: 'IST', city: 'Istanbul', lat: 41.28, lon: 28.75 },
};

export function airport(code: string | null | undefined): Airport | undefined {
  return code ? AIRPORTS[code] : undefined;
}
