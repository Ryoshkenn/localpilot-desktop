import type { HelperElement } from "./helper.ts";

export type Risk = { level: "allow" } | { level: "ask" | "block"; reason: string };

/**
 * Deterministic risk rules, ported from LocalPilot's policy engine. They run
 * before every action no matter what the model says. "ask" needs the user's
 * approval; "block" never runs.
 */
const riskyLabel =
	/\b(delete|remove|erase|trash|discard|destroy|wipe|format|buy|purchase|pay|checkout|check out|place order|order now|subscribe|transfer|send money|wire|donate|sign out|log out|logout|uninstall|reset|factory|revoke|deactivate)\b/i;
const sendLabel = /^(send|post|publish|tweet|reply all|submit payment|confirm payment|confirm purchase)\b/i;

const dangerousKeys = new Map<string, string>([
	["cmd+q", "quits the app"],
	["cmd+alt+q", "logs out"],
	["cmd+shift+q", "logs out"],
	["cmd+delete", "moves items to the Trash"],
	["cmd+backspace", "moves items to the Trash"],
	["cmd+shift+delete", "empties the Trash"],
	["cmd+shift+backspace", "empties the Trash"],
	["cmd+alt+esc", "force quits apps"],
	["ctrl+cmd+q", "locks the screen"],
	["cmd+ctrl+q", "locks the screen"],
]);

export function normalizeKeys(keys: string): string {
	const parts = keys
		.toLowerCase()
		.replace(/⌘/g, "cmd+")
		.replace(/⇧/g, "shift+")
		.replace(/⌥/g, "alt+")
		.replace(/⌃/g, "ctrl+")
		.replace(/\s*[-+ ]\s*/g, "+")
		.split("+")
		.filter(Boolean)
		.map((part) =>
			({ command: "cmd", meta: "cmd", option: "alt", opt: "alt", control: "ctrl", backspace: "delete" })[part] ?? part,
		);
	const modifiers = ["ctrl", "alt", "shift", "cmd"].filter((modifier) => parts.includes(modifier));
	const key = parts.filter((part) => !["ctrl", "alt", "shift", "cmd"].includes(part));
	return [...modifiers, ...key].join("+");
}

export function classifyClick(element: HelperElement | undefined, description?: string): Risk {
	const label = element?.label ?? description ?? "";
	if (riskyLabel.test(label) || sendLabel.test(label)) {
		return { level: "ask", reason: `click "${label}" may delete data, spend money, or send something` };
	}
	return { level: "allow" };
}

export function classifyType(element: HelperElement | undefined, text: string, userTask: string): Risk {
	if (element?.role === "password") {
		// Only type a secret the user wrote into this task themselves.
		if (text && userTask.includes(text)) return { level: "ask", reason: "typing into a password field" };
		return { level: "block", reason: "the agent may not type passwords it was not given in the task" };
	}
	if (/\b\d{13,19}\b/.test(text.replace(/[ -]/g, "")) && !userTask.includes(text)) {
		return { level: "block", reason: "text looks like a card number that the user did not provide" };
	}
	return { level: "allow" };
}

export function classifyKeys(keys: string): Risk {
	const normalized = normalizeKeys(keys);
	const reason = dangerousKeys.get(normalized) ?? dangerousKeys.get(normalized.replace("alt+", ""));
	if (reason) return { level: "ask", reason: `${normalized} ${reason}` };
	return { level: "allow" };
}

export function classifyURL(raw: string): Risk {
	const text = raw.trim();
	if (/[\\\s]/.test(text)) return { level: "block", reason: "URL contains spaces or backslashes" };
	const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(text) ? text : `https://${text}`;
	let url: URL;
	try {
		url = new URL(withScheme);
	} catch {
		return { level: "block", reason: "not a valid URL" };
	}
	if (url.protocol !== "http:" && url.protocol !== "https:") {
		return { level: "block", reason: `${url.protocol} URLs are not allowed; only web pages` };
	}
	if (!url.hostname) return { level: "block", reason: "URL has no host" };
	return { level: "allow" };
}

export function classifyApp(name: string): Risk {
	if (/^(terminal|iterm|iterm2|warp|ghostty|kitty|alacritty|wezterm)$/i.test(name.trim())) {
		return { level: "ask", reason: `${name} can run arbitrary commands` };
	}
	return { level: "allow" };
}
