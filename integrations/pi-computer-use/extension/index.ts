/**
 * LocalPilot computer use for pi.
 *
 * Adds tools that let the model operate macOS through the accessibility tree
 * (numbered elements) with a vision-grounding fallback, plus a lean
 * "computer mode" tuned for small local models:
 *
 *   pi --computer                 start in computer mode
 *   /computer on | off | tools    switch modes inside pi
 *
 * Every action passes deterministic safety rules first (see policy.ts);
 * risky ones need approval in the UI.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { groundTarget, type VisionAsk } from "./grounding.ts";
import { HelperClient, type HelperElement, type Observation, type ScreenshotResult } from "./helper.ts";
import {
	defaultFormatOptions,
	describeChange,
	type FormatOptions,
	formatObservation,
	isTextRole,
	resolveTarget,
	SCREEN_MARKER,
	screenSignature,
} from "./observation.ts";
import {
	classifyApp,
	classifyClick,
	classifyKeys,
	classifyType,
	classifyURL,
	normalizeKeys,
	type Risk,
} from "./policy.ts";
import { computerSystemPrompt } from "./prompt.ts";

export const TOOL_NAMES = ["look", "click", "type_text", "press_key", "scroll", "open_app", "open_url"];

interface Config {
	maxElements: number;
	maxTextChars: number;
	/** "auto": ground with the session model when it accepts images. "off": never. */
	grounding: "auto" | "off";
	/** "provider/model-id" of a dedicated grounding model, e.g. Holo. */
	groundingModel?: string;
	/** Skip approval prompts for risky actions (blocked actions stay blocked). */
	autoApprove: boolean;
	/** Activate the tools in normal coding mode too. */
	alwaysOn: boolean;
}

function loadConfig(): Config {
	const config: Config = {
		maxElements: defaultFormatOptions.maxElements,
		maxTextChars: defaultFormatOptions.maxTextChars,
		grounding: "auto",
		autoApprove: false,
		alwaysOn: false,
	};
	const path = join(homedir(), ".pi", "agent", "computer-use.json");
	if (existsSync(path)) {
		try {
			Object.assign(config, JSON.parse(readFileSync(path, "utf8")));
		} catch {}
	}
	const env = process.env;
	if (env.LOCALPILOT_AUTO_APPROVE) config.autoApprove = env.LOCALPILOT_AUTO_APPROVE === "1";
	if (env.LOCALPILOT_GROUNDING) config.grounding = env.LOCALPILOT_GROUNDING === "off" ? "off" : "auto";
	if (env.LOCALPILOT_GROUNDING_MODEL) config.groundingModel = env.LOCALPILOT_GROUNDING_MODEL;
	if (env.LOCALPILOT_MAX_ELEMENTS) config.maxElements = Number(env.LOCALPILOT_MAX_ELEMENTS) || config.maxElements;
	return config;
}

type ToolResult = { content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[]; details: unknown };

export default function computerUse(pi: ExtensionAPI) {
	const config = loadConfig();
	const format: FormatOptions = { maxElements: config.maxElements, maxTextChars: config.maxTextChars };
	const helper = new HelperClient();

	let lastObservation: Observation | undefined;
	let computerMode = false;
	let savedTools: string[] | undefined;
	let currentTask = "";
	/** Signatures of recent actions and whether each changed the screen. */
	let recentActions: { signature: string; changed: boolean }[] = [];

	// MARK: Helpers

	async function observe(): Promise<Observation> {
		lastObservation = await helper.request<Observation>("observe", { maxElements: 150 });
		return lastObservation;
	}

	async function currentScreen(): Promise<Observation> {
		return lastObservation ?? observe();
	}

	async function approve(ctx: ExtensionContext, risk: Risk, action: string): Promise<void> {
		if (risk.level === "allow") return;
		if (risk.level === "block") throw new Error(`Blocked by safety policy: ${risk.reason}.`);
		if (config.autoApprove) return;
		if (!ctx.hasUI) {
			throw new Error(`Needs the user's approval (${risk.reason}), which is not available in this mode. Ask the user to do this step.`);
		}
		const ok = await ctx.ui.confirm("Allow computer action?", `${action}\n\nReason: ${risk.reason}`);
		if (!ok) throw new Error(`The user declined: ${action}. Do not try it again; ask the user what to do instead.`);
	}

	/** Re-observe after an action and report what changed, with loop detection. */
	async function finish(signature: string, outcome: string, before: Observation | undefined): Promise<ToolResult> {
		const after = await observe();
		const change = describeChange(before, after);
		const changed = !before || screenSignature(before) !== screenSignature(after);
		recentActions.push({ signature, changed });
		recentActions = recentActions.slice(-6);
		const repeats = recentActions.filter((action) => action.signature === signature && !action.changed).length;
		let warning = "";
		if (!changed && repeats >= 2) {
			warning = `\nWarning: you have done this ${repeats} times and nothing changed. Do something different.`;
		}
		const text = `${outcome}${change ? ` ${change}` : ""}${warning}\n${SCREEN_MARKER}\n${formatObservation(after, format)}`;
		return { content: [{ type: "text", text }], details: { outcome, change, app: after.app, window: after.window } };
	}

	/** Refuse an exact repeat of an action that already failed to change anything twice. */
	function guardRepeat(signature: string): void {
		const stuck = recentActions.slice(-3).filter((action) => action.signature === signature && !action.changed).length;
		if (stuck >= 2) {
			throw new Error(
				`Refusing to repeat "${signature}" a third time: it did not change the screen. Try a different element, a keyboard shortcut, or scrolling.\n${SCREEN_MARKER}\n${lastObservation ? formatObservation(lastObservation, format) : ""}`,
			);
		}
	}

	function notFound(target: string, candidates: HelperElement[], screen: Observation): Error {
		const hint = candidates.length
			? ` Closest matches: ${candidates.map((element) => `[${element.id}] ${element.role} "${element.label}"`).join(", ")}.`
			: "";
		return new Error(
			`No element matches "${target}".${hint} Use a [number] from the list below.\n${SCREEN_MARKER}\n${formatObservation(screen, format)}`,
		);
	}

	/** Vision model used for screenshots-to-coordinates: a configured one, else the session model. */
	function visionAsk(ctx: ExtensionContext): VisionAsk | undefined {
		if (config.grounding === "off") return undefined;
		let model = ctx.model;
		if (config.groundingModel) {
			const slash = config.groundingModel.indexOf("/");
			const found = slash > 0
				? ctx.modelRegistry.find(config.groundingModel.slice(0, slash), config.groundingModel.slice(slash + 1))
				: undefined;
			if (found) model = found;
		}
		if (!model || !model.input?.includes("image")) return undefined;
		const chosen = model;
		return async (prompt, jpegBase64, signal) => {
			const message = await ctx.modelRegistry
				.streamSimple(
					chosen,
					{
						messages: [
							{
								role: "user",
								content: [
									{ type: "image", data: jpegBase64, mimeType: "image/jpeg" },
									{ type: "text", text: prompt },
								],
								timestamp: Date.now(),
							},
						],
					},
					{ maxTokens: 96, temperature: 0, signal } as any,
				)
				.result();
			return message.content
				.filter((part): part is { type: "text"; text: string } => part.type === "text")
				.map((part) => part.text)
				.join("");
		};
	}

	function looksLikeId(target: string): boolean {
		return /^\s*\[?#?\d{1,4}\]?\s*$/.test(target);
	}

	// MARK: Argument coercion (small models get key names wrong)

	function pick(args: any, ...keys: string[]): unknown {
		if (!args || typeof args !== "object") return undefined;
		for (const key of keys) if (args[key] !== undefined && args[key] !== null) return args[key];
		return undefined;
	}

	function asString(value: unknown): string | undefined {
		if (value === undefined || value === null) return undefined;
		if (Array.isArray(value)) return value.map(String).join("+");
		return String(value);
	}

	function asBool(value: unknown): boolean | undefined {
		if (value === undefined) return undefined;
		if (typeof value === "boolean") return value;
		return ["true", "yes", "1"].includes(String(value).toLowerCase());
	}

	const targetKeys = ["target", "id", "element", "element_id", "elementId", "index", "label", "name", "button", "ref"];

	// MARK: Tools

	pi.registerTool({
		name: "look",
		label: "Look at screen",
		description:
			"Describe what is on the Mac screen now: the app, window, numbered clickable elements, and visible text. Set screenshot to true to also get an image with the element numbers drawn on it.",
		promptSnippet: "look: see the Mac screen as a numbered list of elements",
		parameters: Type.Object({
			screenshot: Type.Optional(Type.Boolean({ description: "Also attach a screenshot with numbered boxes" })),
		}),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({ screenshot: asBool(pick(args, "screenshot", "image", "visual")) }),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			const screen = await observe();
			const content: ToolResult["content"] = [{ type: "text", text: `${SCREEN_MARKER}\n${formatObservation(screen, format)}` }];
			if (params.screenshot) {
				if (ctx.model?.input?.includes("image")) {
					const shot = await helper.request<ScreenshotResult>("screenshot", { area: "window", maxWidth: 1024, marks: true });
					content.push({ type: "image", data: shot.jpegBase64, mimeType: "image/jpeg" });
				} else {
					content.push({ type: "text", text: "(The current model cannot see images; use the element list.)" });
				}
			}
			return { content, details: { app: screen.app, window: screen.window } };
		},
	});

	pi.registerTool({
		name: "click",
		label: "Click",
		description:
			'Click an element on the Mac screen. target is the element number from the screen list (e.g. "12"), its label (e.g. "Save"), or a short visual description (e.g. "the blue Sign in button").',
		promptSnippet: "click: click an on-screen element by number or label",
		parameters: Type.Object({
			target: Type.String({ description: 'Element number like "12", or its label' }),
			double: Type.Optional(Type.Boolean({ description: "Double-click" })),
			right: Type.Optional(Type.Boolean({ description: "Right-click" })),
		}),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({
			target: asString(pick(args, ...targetKeys, "text", "description")) ?? "",
			double: asBool(pick(args, "double", "double_click", "doubleClick")),
			right: asBool(pick(args, "right", "right_click", "rightClick")),
		}),
		async execute(_id, params, signal, _onUpdate, ctx) {
			const count = params.double ? 2 : 1;
			const button = params.right ? "right" : "left";
			const signature = `click ${params.target}${params.double ? " double" : ""}${params.right ? " right" : ""}`;
			guardRepeat(signature);
			let screen = await currentScreen();
			let resolution = resolveTarget(params.target, screen.elements);
			if (!resolution.element && !looksLikeId(params.target)) {
				// The screen may have changed since the last look.
				screen = await observe();
				resolution = resolveTarget(params.target, screen.elements);
			}

			if (resolution.element) {
				const element = resolution.element;
				await approve(ctx, classifyClick(element), `Click [${element.id}] ${element.role} "${element.label}"`);
				try {
					await helper.request("click", { id: element.id, count, button });
				} catch (error) {
					if (!String(error).includes("not on screen")) throw error;
					// Stale id: find the same element in a fresh observation.
					const fresh = await observe();
					const again = resolveTarget(element.label || params.target, fresh.elements);
					if (!again.element) throw notFound(params.target, again.candidates, fresh);
					await helper.request("click", { id: again.element.id, count, button });
				}
				return finish(signature, `Clicked [${element.id}] ${element.role}${element.label ? ` "${element.label}"` : ""}.`, screen);
			}

			if (looksLikeId(params.target)) {
				const fresh = await observe();
				throw new Error(
					`There is no element ${params.target} on the current screen. Use a number from this list.\n${SCREEN_MARKER}\n${formatObservation(fresh, format)}`,
				);
			}

			// Not in the accessibility tree: find it visually.
			const ask = visionAsk(ctx);
			if (!ask) throw notFound(params.target, resolution.candidates, screen);
			const shot = await helper.request<ScreenshotResult>("screenshot", { area: "window", maxWidth: 1280 });
			const point = await groundTarget(params.target, shot, ask, signal);
			if (!point) throw notFound(params.target, resolution.candidates, screen);
			await approve(ctx, classifyClick(undefined, params.target), `Click "${params.target}" at (${point.x}, ${point.y})`);
			await helper.request("click", { x: point.x, y: point.y, count, button });
			return finish(signature, `Clicked "${params.target}" (found visually at ${point.x},${point.y}).`, screen);
		},
	});

	pi.registerTool({
		name: "type_text",
		label: "Type text",
		description:
			"Type text on the Mac. If target is given (element number or label of a text field), that field is focused and its old text replaced first. Set submit to true to press Enter after typing.",
		promptSnippet: "type_text: type into a text field, optionally pressing Enter",
		parameters: Type.Object({
			text: Type.String({ description: "The text to type" }),
			target: Type.Optional(Type.String({ description: 'Text field number like "5", or its label' })),
			submit: Type.Optional(Type.Boolean({ description: "Press Enter after typing" })),
		}),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({
			text: asString(pick(args, "text", "value", "content", "query", "input", "string")) ?? "",
			target: asString(pick(args, ...targetKeys, "field", "into")),
			submit: asBool(pick(args, "submit", "enter", "press_enter", "pressEnter")),
		}),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			let screen = await currentScreen();
			let element: HelperElement | undefined;
			if (params.target) {
				let resolution = resolveTarget(params.target, screen.elements, true);
				if (!resolution.element && !looksLikeId(params.target)) {
					screen = await observe();
					resolution = resolveTarget(params.target, screen.elements, true);
				}
				if (!resolution.element) throw notFound(params.target, resolution.candidates, screen);
				element = resolution.element;
			} else {
				element = screen.elements.find((candidate) => candidate.focused);
			}
			const signature = `type ${params.target ?? ""} ${params.text}`;
			guardRepeat(signature);
			await approve(ctx, classifyType(element, params.text, currentTask), `Type "${params.text}"${element ? ` into [${element.id}] "${element.label}"` : ""}`);

			const targeted = params.target !== undefined && element !== undefined;
			// Replace a single-line field's contents; never wipe a document.
			const replace = targeted && isTextRole(element!.role) && element!.role !== "textarea";
			await helper.request("type", {
				text: params.text,
				...(targeted ? { id: element!.id } : {}),
				replace,
				submit: params.submit ?? false,
			});
			const where = element ? ` into [${element.id}] ${element.role}${element.label ? ` "${element.label}"` : ""}` : "";
			return finish(signature, `Typed "${params.text}"${where}${params.submit ? " and pressed Enter" : ""}.`, screen);
		},
	});

	pi.registerTool({
		name: "press_key",
		label: "Press key",
		description: 'Press a key or shortcut on the Mac, e.g. "return", "escape", "tab", "cmd+t", "cmd+shift+n", "down".',
		promptSnippet: "press_key: press a key or keyboard shortcut",
		parameters: Type.Object({ keys: Type.String({ description: 'Key or shortcut, e.g. "cmd+l"' }) }),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({ keys: asString(pick(args, "keys", "key", "combo", "shortcut", "hotkey", "name")) ?? "" }),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			const keys = normalizeKeys(params.keys);
			const signature = `key ${keys}`;
			guardRepeat(signature);
			await approve(ctx, classifyKeys(keys), `Press ${keys}`);
			const before = await currentScreen();
			await helper.request("key", { keys });
			return finish(signature, `Pressed ${keys}.`, before);
		},
	});

	pi.registerTool({
		name: "scroll",
		label: "Scroll",
		description: "Scroll the Mac screen up or down (or left/right), optionally inside a specific element.",
		promptSnippet: "scroll: scroll to reveal more of the page",
		parameters: Type.Object({
			direction: Type.Union([Type.Literal("up"), Type.Literal("down"), Type.Literal("left"), Type.Literal("right")]),
			target: Type.Optional(Type.String({ description: "Element number to scroll inside" })),
		}),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => {
			const direction = (asString(pick(args, "direction", "dir", "way")) ?? "down").toLowerCase();
			return {
				direction: (["up", "down", "left", "right"].includes(direction) ? direction : "down") as "up" | "down" | "left" | "right",
				target: asString(pick(args, ...targetKeys)),
			};
		},
		async execute(_id, params) {
			const screen = await currentScreen();
			const element = params.target ? resolveTarget(params.target, screen.elements).element : undefined;
			const signature = `scroll ${params.direction} ${params.target ?? ""}`;
			await helper.request("scroll", { direction: params.direction, amount: 8, ...(element ? { id: element.id } : {}) });
			return finish(signature, `Scrolled ${params.direction}.`, screen);
		},
	});

	pi.registerTool({
		name: "open_app",
		label: "Open app",
		description: 'Open (or switch to) a Mac app by name, e.g. "Safari", "Notes", "Calculator", "System Settings".',
		promptSnippet: "open_app: launch or switch to an app",
		parameters: Type.Object({ name: Type.String({ description: "App name" }) }),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({ name: asString(pick(args, "name", "app", "application", "app_name", "target")) ?? "" }),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			await approve(ctx, classifyApp(params.name), `Open ${params.name}`);
			const before = lastObservation;
			const opened = await helper.request<{ app: string }>("open_app", { name: params.name });
			return finish(`open ${params.name}`, `Opened ${opened.app}.`, before);
		},
	});

	pi.registerTool({
		name: "open_url",
		label: "Open URL",
		description: "Open a web page in the browser. Uses the browser already in use, or the default browser.",
		promptSnippet: "open_url: open a website",
		parameters: Type.Object({
			url: Type.String({ description: "Web address, e.g. https://example.com" }),
			app: Type.Optional(Type.String({ description: 'Browser to use, e.g. "Safari"' })),
		}),
		defaultActive: config.alwaysOn,
		executionMode: "sequential",
		prepareArguments: (args: any) => ({
			url: asString(pick(args, "url", "link", "address", "href", "website", "target")) ?? "",
			app: asString(pick(args, "app", "browser")),
		}),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			await approve(ctx, classifyURL(params.url), `Open ${params.url}`);
			const before = lastObservation;
			await helper.request("open_url", { url: params.url, ...(params.app ? { app: params.app } : {}) }, 45_000);
			return finish(`url ${params.url}`, `Opened ${params.url}.`, before);
		},
	});

	// MARK: Computer mode

	function enableComputerMode(ctx: ExtensionContext, lean: boolean) {
		if (!savedTools) savedTools = pi.getActiveTools();
		if (lean) {
			computerMode = true;
			pi.setActiveTools(TOOL_NAMES);
		} else {
			computerMode = false;
			pi.setActiveTools([...new Set([...savedTools, ...TOOL_NAMES])]);
		}
		ctx.ui.setStatus("computer-use", lean ? "computer mode" : "computer tools");
	}

	function disableComputerMode(ctx: ExtensionContext) {
		computerMode = false;
		pi.setActiveTools((savedTools ?? pi.getActiveTools()).filter((name) => config.alwaysOn || !TOOL_NAMES.includes(name)));
		savedTools = undefined;
		ctx.ui.setStatus("computer-use", undefined);
		helper.request("release").catch(() => {});
	}

	pi.registerFlag("computer", {
		type: "boolean",
		description: "Start in LocalPilot computer mode (lean prompt and computer tools only, for small local models)",
	});

	pi.registerCommand("computer", {
		description: "Computer use: /computer on (lean mode for small models), /computer tools (add tools to coding mode), /computer off",
		handler: async (args, ctx) => {
			const arg = args.trim().toLowerCase();
			if (arg === "off") {
				disableComputerMode(ctx);
				ctx.ui.notify("Computer use off", "info");
				return;
			}
			if (arg === "tools") {
				enableComputerMode(ctx, false);
				ctx.ui.notify("Computer tools added to this session", "info");
				return;
			}
			if (arg === "status") {
				const permissions = await helper.request("permissions").catch((error) => ({ error: String(error) }));
				ctx.ui.notify(`Computer mode: ${computerMode ? "on" : "off"}; permissions: ${JSON.stringify(permissions)}`, "info");
				return;
			}
			enableComputerMode(ctx, true);
			const permissions = await helper.request<{ accessibility: boolean; screenRecording: boolean }>("permissions").catch(() => undefined);
			if (permissions && (!permissions.accessibility || !permissions.screenRecording)) {
				ctx.ui.notify(
					"Grant your terminal Accessibility and Screen Recording access in System Settings > Privacy & Security, then restart it.",
					"warning",
				);
			}
			ctx.ui.notify("Computer mode on. Describe a task; press Esc to stop the agent.", "info");
		},
	});

	pi.on("session_start", (_event, ctx) => {
		if (pi.getFlag("computer") === true) enableComputerMode(ctx, true);
	});

	pi.on("before_agent_start", async (event) => {
		currentTask = event.prompt;
		recentActions = [];
		if (!computerMode) return;
		// Start every task with a fresh look so the model needn't spend a turn on it.
		let screenText = "";
		try {
			const screen = await observe();
			screenText = formatObservation(screen, format);
		} catch (error) {
			screenText = `(Could not read the screen: ${String(error)})`;
		}
		return {
			systemPrompt: computerSystemPrompt(),
			message: {
				customType: "computer-screen",
				content: `Current screen:\n${SCREEN_MARKER}\n${screenText}`,
				display: false,
			},
		};
	});

	// Old screens are stale and expensive for a small model's context: keep
	// only the newest one in full.
	pi.on("context", (event) => {
		const messages = event.messages as any[];
		let newest = -1;
		messages.forEach((message, index) => {
			if (isScreenMessage(message)) newest = index;
		});
		if (newest < 0) return;
		let changed = false;
		const pruned = messages.map((message, index) => {
			if (index === newest || !isScreenMessage(message)) return message;
			changed = true;
			return stripScreen(message);
		});
		return changed ? { messages: pruned } : undefined;
	});

	pi.on("session_shutdown", () => {
		helper.dispose();
	});
}

function isScreenMessage(message: any): boolean {
	if (message?.role === "toolResult" && TOOL_NAMES.includes(message.toolName)) return contentHasScreen(message.content);
	if (message?.role === "custom" && message.customType === "computer-screen") return true;
	return false;
}

function contentHasScreen(content: unknown): boolean {
	if (typeof content === "string") return content.includes(SCREEN_MARKER);
	return Array.isArray(content) && content.some((part: any) => part?.type === "image" || (part?.type === "text" && part.text.includes(SCREEN_MARKER)));
}

function stripScreen(message: any): any {
	const strip = (text: string) => {
		const index = text.indexOf(SCREEN_MARKER);
		return index < 0 ? text : `${text.slice(0, index).trimEnd()}\n(older screen omitted)`;
	};
	if (typeof message.content === "string") return { ...message, content: strip(message.content) };
	return {
		...message,
		content: message.content
			.filter((part: any) => part?.type !== "image")
			.map((part: any) => (part?.type === "text" ? { ...part, text: strip(part.text) } : part)),
	};
}
