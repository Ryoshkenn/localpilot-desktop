import type { HelperElement, Observation } from "./helper.ts";

/** Marker that separates an action's outcome from the screen listing in tool results. */
export const SCREEN_MARKER = "--- screen ---";

export interface FormatOptions {
	maxElements: number;
	maxTextChars: number;
}

export const defaultFormatOptions: FormatOptions = { maxElements: 80, maxTextChars: 1200 };

/**
 * Render an observation as compact text: one short line per element, which a
 * 4B model can scan and refer to by number.
 */
export function formatObservation(observation: Observation, options: FormatOptions = defaultFormatOptions): string {
	if (!observation.app) return observation.note ?? "No app is open. Use open_app to start one.";
	const lines: string[] = [];
	const title = observation.window ? ` - window "${observation.window}"` : "";
	lines.push(`App: ${observation.app}${title}`);
	if (observation.url) lines.push(`URL: ${observation.url}`);
	if (observation.scroll !== undefined) lines.push(`Scroll: ${describeScroll(observation.scroll)}`);

	const elements = observation.elements;
	if (elements.length === 0) {
		lines.push("Elements: none found (try look with screenshot=true, or press_key / scroll)");
	} else {
		lines.push("Elements:");
		for (const element of elements.slice(0, options.maxElements)) lines.push(formatElement(element));
		const hidden = elements.length - options.maxElements;
		if (hidden > 0) lines.push(`(${hidden} more not shown; target them by label, or scroll)`);
		else if (observation.truncated) lines.push("(more elements exist; scroll to see them)");
	}

	// Labels already listed as elements needn't be repeated as text.
	const labels = new Set(elements.map((element) => element.label.trim().toLowerCase()).filter(Boolean));
	const text = observation.text
		.split(" | ")
		.filter((segment) => !labels.has(segment.trim().toLowerCase()))
		.join(" | ")
		.trim();
	if (text) {
		const bounded = text.length > options.maxTextChars ? `${text.slice(0, options.maxTextChars)}...` : text;
		// Headings on their own lines, so titles stand out from body text.
		const rendered = bounded.replace(/(?:^| \| )# ([^|]+)/g, (_match, heading: string) => `\n# ${heading.trim()}\n`).replace(/\n\s*\| /g, "\n").trim();
		lines.push(`Text on screen:\n${rendered}`);
	} else {
		lines.push("Text on screen: (none)");
	}
	return lines.join("\n");
}

export function describeScroll(position: number): string {
	if (position <= 0.01) return "at the top (more below)";
	if (position >= 0.99) return "at the bottom";
	return `${Math.round(position * 100)}% down (more below)`;
}

export function formatElement(element: HelperElement): string {
	let line = `[${element.id}] ${element.role}`;
	if (element.label) line += ` "${element.label}"`;
	if (element.value !== undefined && element.value !== "") line += ` = "${element.value}"`;
	else if (element.value === "" && isTextRole(element.role)) line += " (empty)";
	if (element.focused) line += " (focused)";
	return line;
}

export function isTextRole(role: string): boolean {
	return ["textfield", "textarea", "searchfield", "password", "combobox", "datefield"].includes(role);
}

/** A short, human-readable account of what changed between two observations. */
export function describeChange(before: Observation | undefined, after: Observation): string {
	if (!before) return "";
	const changes: string[] = [];
	if (before.app !== after.app) changes.push(`now in ${after.app ?? "no app"}`);
	else if (before.window !== after.window) changes.push(`window is now "${after.window ?? ""}"`);
	if (before.url !== after.url && after.url) changes.push(`page is now ${after.url}`);
	const beforeFocus = before.elements.find((element) => element.focused);
	const afterFocus = after.elements.find((element) => element.focused);
	if (afterFocus && (!beforeFocus || signature(beforeFocus) !== signature(afterFocus))) {
		changes.push(`focus on [${afterFocus.id}] ${afterFocus.role}${afterFocus.label ? ` "${afterFocus.label}"` : ""}`);
	}
	if (changes.length === 0 && screenSignature(before) === screenSignature(after)) {
		return "Nothing visible changed.";
	}
	return changes.length ? `Screen changed: ${changes.join("; ")}.` : "Screen changed.";
}

function signature(element: HelperElement): string {
	return `${element.role}|${element.label}|${element.value ?? ""}`;
}

export function screenSignature(observation: Observation): string {
	return [
		observation.app,
		observation.window,
		observation.url,
		String(observation.scroll ?? ""),
		observation.text.slice(0, 2000),
		...observation.elements.map(signature),
	].join("\n");
}

// MARK: - Resolving targets

const fillerWords = new Set([
	"the", "a", "an", "on", "in", "into", "of", "to", "field", "button", "link", "tab", "menu", "item", "icon", "box",
	"textfield", "text", "input", "checkbox", "option", "element", "labeled", "labelled", "called", "named", "click",
	"and", "or", "for", "your", "my", "bar", "area",
]);

/** Words models use for a thing that apps label differently. */
const synonyms: Record<string, string> = { url: "address", location: "address", omnibox: "address", magnifier: "search" };

function normalize(text: string): string {
	return text
		.toLowerCase()
		.replace(/[“”"'`]/g, "")
		.replace(/[^\p{L}\p{N}]+/gu, " ")
		.trim();
}

function tokens(text: string): string[] {
	return normalize(text)
		.split(" ")
		.map((token) => synonyms[token] ?? token)
		.filter((token) => token && !fillerWords.has(token));
}

export interface Resolution {
	element?: HelperElement;
	/** Plausible elements when the target was ambiguous or not found. */
	candidates: HelperElement[];
	/** How the target was understood, for the tool result. */
	how?: "id" | "label";
}

/**
 * Turn what the model wrote ("12", "#12", "[12]", "Save", "the Save button")
 * into one element. Numbers win; otherwise labels are fuzzy-matched, with a
 * bonus for text fields when the model is about to type.
 */
export function resolveTarget(
	raw: string | number | undefined,
	elements: HelperElement[],
	preferText = false,
): Resolution {
	if (raw === undefined || raw === null || String(raw).trim() === "") return { candidates: [] };
	const text = String(raw).trim();

	const idMatch = /^(?:\[|#|id\s*|element\s*|item\s*)?\s*(\d{1,4})\s*\]?$/i.exec(text) ??
		/^(?:\[(\d{1,4})\])/.exec(text);
	if (idMatch) {
		const id = Number(idMatch[1]);
		const element = elements.find((candidate) => candidate.id === id);
		return element ? { element, candidates: [], how: "id" } : { candidates: [] };
	}

	const wanted = normalize(text);
	const wantedTokens = tokens(text);
	const roleHint = /\b(button|link|field|tab|checkbox|menu|row|popup|search)\b/i.exec(text)?.[1]?.toLowerCase();

	const scored = elements
		.map((element) => ({ element, score: scoreElement(element, wanted, wantedTokens, roleHint, preferText) }))
		.filter((entry) => entry.score > 0)
		.sort((a, b) => b.score - a.score || a.element.id - b.element.id);

	const best = scored[0];
	if (!best || best.score < 45) return { candidates: scored.slice(0, 5).map((entry) => entry.element) };
	const second = scored[1];
	const exact = best.score >= 100;
	if (exact || !second || best.score - second.score >= 8) {
		return { element: best.element, candidates: [], how: "label" };
	}
	// Ties between identical labels: take the first in reading order.
	if (second && normalize(second.element.label) === normalize(best.element.label)) {
		return { element: best.element, candidates: [], how: "label" };
	}
	return { candidates: scored.slice(0, 5).map((entry) => entry.element) };
}

function scoreElement(
	element: HelperElement,
	wanted: string,
	wantedTokens: string[],
	roleHint: string | undefined,
	preferText: boolean,
): number {
	const label = normalize(element.label);
	const value = normalize(element.value ?? "");
	let score = 0;
	if (label && label === wanted) score = 100;
	else if (label && wantedTokens.length && label === wantedTokens.join(" ")) score = 98;
	else if (label && label.startsWith(wanted) && wanted.length >= 2) score = 80 - Math.min(20, label.length - wanted.length) / 2;
	else if (label && wanted.length >= 3 && label.includes(wanted)) score = 65 - Math.min(20, label.length - wanted.length) / 2;
	else if (label.length >= 3 && wanted.includes(label)) score = 55;
	else if (wantedTokens.length) {
		const labelTokens = new Set(tokens(element.label));
		const hits = wantedTokens.filter((token) => labelTokens.has(token)).length;
		if (hits) score = (hits / Math.max(wantedTokens.length, labelTokens.size)) * 60;
	}
	if (score === 0 && value && wanted.length >= 3 && value.includes(wanted)) score = 45;
	if (score === 0) return 0;
	if (roleHint && roleMatches(element.role, roleHint)) score += 10;
	if (preferText && isTextRole(element.role)) score += 20;
	return score;
}

function roleMatches(role: string, hint: string): boolean {
	if (hint === "field" || hint === "search") return isTextRole(role);
	if (hint === "menu") return role.startsWith("menu");
	return role === hint;
}
