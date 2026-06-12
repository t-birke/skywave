import * as THREE from "three";
import landGeoJSON from "./ne_110m_land.json";

export function latLngToVector3(
  lat: number,
  lng: number,
  radius: number
): THREE.Vector3 {
  const phi = (90 - lat) * (Math.PI / 180);
  const theta = (lng + 180) * (Math.PI / 180);
  return new THREE.Vector3(
    -(radius * Math.sin(phi) * Math.cos(theta)),
    radius * Math.cos(phi),
    radius * Math.sin(phi) * Math.sin(theta)
  );
}

export function latLngToArray(
  lat: number,
  lng: number,
  radius: number
): [number, number, number] {
  const v = latLngToVector3(lat, lng, radius);
  return [v.x, v.y, v.z];
}

type Coord = [number, number]; // [lat, lng]

interface GeoJSONFeature {
  type: string;
  geometry: {
    type: "Polygon" | "MultiPolygon";
    coordinates: number[][][] | number[][][][];
  };
}

function parseGeoJSONToLandmasses(): Coord[][] {
  const features = (landGeoJSON as { features: GeoJSONFeature[] }).features;
  const result: Coord[][] = [];

  for (const feature of features) {
    const { type, coordinates } = feature.geometry;
    if (type === "Polygon") {
      const ring = (coordinates as number[][][])[0];
      result.push(ring.map(([lng, lat]) => [lat, lng] as Coord));
    } else if (type === "MultiPolygon") {
      for (const polygon of coordinates as number[][][][]) {
        const ring = polygon[0];
        result.push(ring.map(([lng, lat]) => [lat, lng] as Coord));
      }
    }
  }

  return result;
}

const landmasses = parseGeoJSONToLandmasses();

export function createEarthTexture(
  width: number = 1024,
  height: number = 512,
  landColor: string = "#0f2a3a",
  oceanColor: string = "#060a12",
  borderColor: string = "#00b4d8",
  borderWidth: number = 1.5,
): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d")!;

  ctx.fillStyle = oceanColor;
  ctx.fillRect(0, 0, width, height);

  function toPixel(lat: number, lng: number): [number, number] {
    const x = ((lng + 180) / 360) * width;
    const y = ((90 - lat) / 180) * height;
    return [x, y];
  }

  // Draw filled land — batched into one path
  ctx.fillStyle = landColor;
  ctx.beginPath();
  for (const coords of landmasses) {
    const [sx, sy] = toPixel(coords[0][0], coords[0][1]);
    ctx.moveTo(sx, sy);
    for (let i = 1; i < coords.length; i++) {
      const prevLng = coords[i - 1][1];
      const currLng = coords[i][1];
      const [x, y] = toPixel(coords[i][0], currLng);
      if (Math.abs(currLng - prevLng) > 180) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.closePath();
  }
  ctx.fill();

  // Draw borders — batched into one path
  ctx.strokeStyle = borderColor;
  ctx.lineWidth = borderWidth;
  ctx.globalAlpha = 0.5;
  ctx.beginPath();
  for (const coords of landmasses) {
    const [sx, sy] = toPixel(coords[0][0], coords[0][1]);
    ctx.moveTo(sx, sy);
    for (let i = 1; i < coords.length; i++) {
      const prevLng = coords[i - 1][1];
      const currLng = coords[i][1];
      const [x, y] = toPixel(coords[i][0], currLng);
      if (Math.abs(currLng - prevLng) > 180) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.closePath();
  }
  ctx.stroke();
  ctx.globalAlpha = 1;

  return canvas;
}
