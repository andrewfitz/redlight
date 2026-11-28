import type { RedlightRuntime } from "../redlight/runtime.js";
import type { Status } from "../redlight/types.js";

export type ActionSurface = {
  id: string;
  setTitle(title?: string): Promise<void>;
  setImage(image?: string): Promise<void>;
  showAlert(): Promise<void>;
};

export function safeActionUpdate(operation: Promise<void>): void {
  void operation.catch(() => undefined);
}

export function displayValue(level: { target: number; set?: number } | undefined): string {
  if (!level) return "--";
  return `${Math.round(level.target)}%`;
}

export type ColorUnit = "percent" | "kelvin";
const units = new Map<string, ColorUnit>();

export function setColorUnit(id: string, value?: unknown): void {
  if (value === "kelvin") units.set(id, "kelvin");
  else units.delete(id);
}

export function colorTempText(status: Status, unit: ColorUnit = "percent"): string {
  const kelvin = status.colorKelvin?.target;
  if (unit === "kelvin" && typeof kelvin === "number" && Number.isFinite(kelvin)) {
    return `${Math.round(kelvin)}K`;
  }
  return displayValue(status.color);
}

export function dialColorText(id: string, status: Status): string {
  return colorTempText(status, units.get(id));
}

export function statusLabel(status: Status): string {
  if (!status.running) return "Offline";
  if (status.peeking) return "Peek";
  if (status.pausedUntil) return "Paused";
  if (status.on === false) return "Off";
  if (status.adaptive) return "Auto";
  return "On";
}

export function activePresetName(status: Status): string {
  switch (status.activePreset) {
    case "day": return "Day";
    case "warm": return "Warm";
    case "sunset": return "Sunset";
    case "night": return "Night";
    case "deep-red":
    case "late": return "Late";
    default: return "Custom";
  }
}

export function statusImage(status: Status, accent = "#f26b4f", label = statusLabel(status), unit: ColorUnit = "percent"): string {
  const color = status.running ? status.color : undefined;
  const whitepoint = status.running ? status.whitepoint : undefined;
  const barWidth = (target = 0) => Math.max(0, Math.min(100, target)) * 1.12;
  const title = escapeXml(status.running ? label : "Offline");
  const colorText = escapeXml(status.running ? colorTempText(status, unit) : "--");
  const whiteText = escapeXml(displayValue(whitepoint));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">
    <rect width="144" height="144" rx="18" fill="#252525"/>
    <g fill="#f6eee8" font-family="Arial, sans-serif" font-weight="600">
      <text x="72" y="30" text-anchor="middle" font-size="23">${title}</text>
      <text x="16" y="64" font-size="23">C ${colorText}</text>
      <text x="16" y="113" font-size="23">W ${whiteText}</text>
    </g>
    <rect x="16" y="72" width="112" height="6" rx="3" fill="#484848"/>
    <rect x="16" y="72" width="${barWidth(color?.target)}" height="6" rx="3" fill="${accent}"/>
    <rect x="16" y="121" width="112" height="6" rx="3" fill="#484848"/>
    <rect x="16" y="121" width="${barWidth(whitepoint?.target)}" height="6" rx="3" fill="#e7c3a2"/>
  </svg>`;
  return `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
}

export function renderKey(action: ActionSurface, status: Status, accent?: string, label?: string): void {
  safeActionUpdate(action.setTitle(""));
  safeActionUpdate(action.setImage(statusImage(status, accent, label, units.get(action.id))));
}

export function bindStatus(
  runtime: RedlightRuntime,
  action: ActionSurface,
  render: (action: ActionSurface, status: Status) => void,
): () => void {
  return runtime.status.subscribe((status) => render(action, status));
}

export async function reportError(action: ActionSurface, error: unknown): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  await Promise.allSettled([
    action.showAlert(),
    action.setTitle(`Error\n${message.slice(0, 24)}`),
  ]);
}

function escapeXml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&apos;",
  })[character] ?? character);
}
