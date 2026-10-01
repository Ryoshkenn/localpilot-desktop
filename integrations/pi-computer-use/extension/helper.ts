import { type ChildProcessWithoutNullStreams, spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const packageRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const helperPackage = join(packageRoot, "helper");
const defaultBinary = join(helperPackage, ".build", "release", "lpcu");

export interface HelperElement {
	id: number;
	role: string;
	label: string;
	value?: string;
	focused?: boolean;
	x: number;
	y: number;
	w: number;
	h: number;
}

export interface Observation {
	app: string | null;
	bundleId?: string;
	window?: string;
	url?: string;
	elements: HelperElement[];
	text: string;
	truncated?: boolean;
	focusedId?: number;
	windowFrame?: { x: number; y: number; w: number; h: number };
	note?: string;
}

export interface ScreenshotResult {
	jpegBase64: string;
	pixelWidth: number;
	pixelHeight: number;
	originX: number;
	originY: number;
	pointWidth: number;
	pointHeight: number;
}

interface Pending {
	resolve: (value: any) => void;
	reject: (error: Error) => void;
	timer: NodeJS.Timeout;
}

/**
 * Talks to the native `lpcu` helper over JSON lines. The helper is started
 * lazily on first use, built from source if needed, and restarted if it dies.
 */
export class HelperClient {
	private process: ChildProcessWithoutNullStreams | undefined;
	private pending = new Map<number, Pending>();
	private nextId = 1;
	private queue: Promise<unknown> = Promise.resolve();

	constructor(private readonly binary = process.env.LPCU_PATH || defaultBinary) {}

	/** Run one command. Commands are serialized: the helper acts on one thing at a time. */
	request<T = any>(cmd: string, args: Record<string, unknown> = {}, timeoutMs = 30_000): Promise<T> {
		const run = this.queue.then(() => this.send<T>(cmd, args, timeoutMs));
		this.queue = run.catch(() => undefined);
		return run;
	}

	private send<T>(cmd: string, args: Record<string, unknown>, timeoutMs: number): Promise<T> {
		const child = this.ensure();
		const id = this.nextId++;
		return new Promise<T>((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`computer helper timed out on ${cmd}`));
			}, timeoutMs);
			this.pending.set(id, { resolve, reject, timer });
			child.stdin.write(`${JSON.stringify({ id, cmd, args })}\n`);
		});
	}

	private ensure(): ChildProcessWithoutNullStreams {
		if (this.process && this.process.exitCode === null && !this.process.killed) return this.process;
		if (!existsSync(this.binary)) HelperClient.build();
		const child = spawn(this.binary, ["serve"], { stdio: ["pipe", "pipe", "pipe"] });
		this.process = child;
		const lines = createInterface({ input: child.stdout });
		lines.on("line", (line) => {
			let message: any;
			try {
				message = JSON.parse(line);
			} catch {
				return;
			}
			const pending = this.pending.get(message.id);
			if (!pending) return;
			this.pending.delete(message.id);
			clearTimeout(pending.timer);
			if (message.ok) pending.resolve(message.result);
			else pending.reject(new Error(message.error ?? "computer helper failed"));
		});
		child.on("exit", () => {
			for (const [id, pending] of this.pending) {
				clearTimeout(pending.timer);
				pending.reject(new Error("computer helper exited"));
				this.pending.delete(id);
			}
			if (this.process === child) this.process = undefined;
		});
		child.stderr.on("data", () => {});
		return child;
	}

	static build(): void {
		const result = spawnSync("swift", ["build", "-c", "release", "--package-path", helperPackage], {
			encoding: "utf8",
			timeout: 600_000,
		});
		if (result.status !== 0 || !existsSync(defaultBinary)) {
			throw new Error(
				`Could not build the computer-use helper (swift build failed). Run: swift build -c release --package-path ${helperPackage}\n${result.stderr ?? ""}`,
			);
		}
	}

	dispose(): void {
		const child = this.process;
		this.process = undefined;
		if (!child) return;
		try {
			child.stdin.end();
		} catch {}
		child.kill();
	}
}
