import type { ScreenshotResult } from "./helper.ts";

export interface GroundedPoint {
	/** Global screen point (top-left origin, points). */
	x: number;
	y: number;
	raw: string;
}

/** Sends one prompt with one JPEG to a vision model and returns its text answer. */
export type VisionAsk = (prompt: string, jpegBase64: string, signal?: AbortSignal) => Promise<string>;

export function groundingPrompt(description: string): string {
	return `Locate the UI element the user wants to click: "${description}". Output its center point in JSON format.`;
}

/**
 * Ask a vision model where something is on a screenshot. Qwen-VL-family
 * models (Qwen3.5, Holo) answer on a 0-1000 scale for both axes, which we map
 * back to screen points through the screenshot's origin and size.
 */
export async function groundTarget(
	description: string,
	shot: ScreenshotResult,
	ask: VisionAsk,
	signal?: AbortSignal,
): Promise<GroundedPoint | undefined> {
	const raw = await ask(groundingPrompt(description), shot.jpegBase64, signal);
	const point = parsePoint(raw);
	if (!point) return undefined;
	return { ...toScreen(point, shot), raw };
}

/**
 * Pull a 0-1000 point out of the many shapes small VLMs produce:
 * `{"point_2d": [x, y]}`, `{"x": .., "y": ..}`, `Click(x, y)`,
 * `{"bbox_2d": [x1, y1, x2, y2]}` (center), or half-broken JSON.
 */
export function parsePoint(raw: string): { x: number; y: number } | undefined {
	const text = raw.replace(/```(?:json)?/g, "").replace(/_2d/gi, "");
	const bbox = /bbox["']?\s*:\s*\[\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)/i.exec(text);
	if (bbox) {
		const [x1, y1, x2, y2] = bbox.slice(1, 5).map(Number);
		return inRange({ x: (x1 + x2) / 2, y: (y1 + y2) / 2 });
	}
	const xy = /\bx["']?\s*[:=]\s*(-?[\d.]+)[\s\S]*?\by["']?\s*[:=]\s*(-?[\d.]+)/i.exec(text);
	if (xy) return inRange({ x: Number(xy[1]), y: Number(xy[2]) });
	const numbers = [...text.matchAll(/-?\d+(?:\.\d+)?/g)].map((match) => Number(match[0]));
	if (numbers.length >= 2) return inRange({ x: numbers[0], y: numbers[1] });
	return undefined;
}

function inRange(point: { x: number; y: number }): { x: number; y: number } | undefined {
	if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return undefined;
	if (point.x < 0 || point.y < 0 || point.x > 1000 || point.y > 1000) return undefined;
	return point;
}

export function toScreen(point: { x: number; y: number }, shot: ScreenshotResult): { x: number; y: number } {
	return {
		x: Math.round(shot.originX + (point.x / 1000) * shot.pointWidth),
		y: Math.round(shot.originY + (point.y / 1000) * shot.pointHeight),
	};
}
