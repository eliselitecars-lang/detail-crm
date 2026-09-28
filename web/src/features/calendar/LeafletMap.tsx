/**
 * The day map's Leaflet canvas (P-18): OpenStreetMap tiles with their
 * attribution, one numbered marker per located stop (route order) and the
 * shop. Loaded lazily (DayMapView) so the calendar never pays for Leaflet
 * unless the map is opened. The browser never geocodes: points come from the
 * iPhone app (set_job_coordinates).
 */
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { useEffect, useRef } from 'react';

export const OSM_TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const OSM_ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a> contributors';

export interface MapStop {
  jobId: string;
  /** 1-based stop number shown on the marker. */
  order: number;
  label: string;
  lat: number;
  lng: number;
}

export interface LeafletMapProps {
  stops: readonly MapStop[];
  shop: { lat: number; lng: number; label: string } | null;
  onOpenJob: (jobId: string) => void;
  className?: string;
}

function markerIcon(text: string, tone: 'stop' | 'shop'): L.DivIcon {
  const span = document.createElement('span');
  span.textContent = text;
  span.className =
    tone === 'stop'
      ? 'bg-primary text-primary-fg ring-surface flex size-7 items-center justify-center rounded-full text-xs font-semibold shadow ring-2'
      : 'bg-ink text-surface ring-surface flex size-7 items-center justify-center rounded-full text-[10px] font-semibold shadow ring-2';
  return L.divIcon({
    html: span,
    className: 'dc-route-marker',
    iconSize: [28, 28],
    iconAnchor: [14, 14],
    popupAnchor: [0, -14],
  });
}

export default function LeafletMap({ stops, shop, onOpenJob, className }: LeafletMapProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<L.Map | null>(null);
  const layerRef = useRef<L.LayerGroup | null>(null);
  const openRef = useRef(onOpenJob);

  useEffect(() => {
    openRef.current = onOpenJob;
  }, [onOpenJob]);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const map = L.map(el, { scrollWheelZoom: false, keyboard: true });
    L.tileLayer(OSM_TILE_URL, { maxZoom: 19, attribution: OSM_ATTRIBUTION }).addTo(map);
    layerRef.current = L.layerGroup().addTo(map);
    mapRef.current = map;
    return () => {
      map.remove();
      mapRef.current = null;
      layerRef.current = null;
    };
  }, []);

  useEffect(() => {
    const map = mapRef.current;
    const layer = layerRef.current;
    if (!map || !layer) return;
    layer.clearLayers();
    const points: L.LatLngExpression[] = [];
    if (shop) {
      points.push([shop.lat, shop.lng]);
      L.marker([shop.lat, shop.lng], {
        icon: markerIcon('Shop', 'shop'),
        title: shop.label,
        alt: shop.label,
        keyboard: true,
      }).addTo(layer);
    }
    const line: L.LatLngExpression[] = shop ? [[shop.lat, shop.lng]] : [];
    for (const stop of stops) {
      points.push([stop.lat, stop.lng]);
      line.push([stop.lat, stop.lng]);
      const popup = document.createElement('div');
      const title = document.createElement('p');
      title.textContent = `${stop.order}. ${stop.label}`;
      title.className = 'font-medium';
      const open = document.createElement('button');
      open.type = 'button';
      open.textContent = 'Open job';
      open.className = 'text-primary-ink mt-1 text-sm underline';
      open.addEventListener('click', () => openRef.current(stop.jobId));
      popup.append(title, open);
      L.marker([stop.lat, stop.lng], {
        icon: markerIcon(String(stop.order), 'stop'),
        title: `Stop ${stop.order}: ${stop.label}`,
        alt: `Stop ${stop.order}: ${stop.label}`,
        keyboard: true,
      })
        .bindPopup(popup)
        .addTo(layer);
    }
    if (line.length > 1) {
      L.polyline(line, { color: 'currentColor', weight: 3, opacity: 0.5, dashArray: '6 6' }).addTo(
        layer,
      );
    }
    if (points.length === 1 && points[0]) map.setView(points[0], 13);
    else if (points.length > 1) map.fitBounds(L.latLngBounds(points), { padding: [32, 32] });
    else map.setView([39.5, -98.35], 3); // nothing located yet: the whole map
  }, [stops, shop]);

  return (
    <div
      ref={containerRef}
      role="region"
      aria-label="Map of the day’s stops"
      className={className}
    />
  );
}
