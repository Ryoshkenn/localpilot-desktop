import assert from "node:assert/strict";
import { test } from "node:test";
import { parsePoint, toScreen } from "./grounding.ts";
import type { HelperElement, Observation } from "./helper.ts";
import { describeChange, formatObservation, resolveTarget } from "./observation.ts";
import { classifyClick, classifyKeys, classifyType, classifyURL, normalizeKeys } from "./policy.ts";

const element = (id: number, role: string, label: string, extra: Partial<HelperElement> = {}): HelperElement => ({
	id,
	role,
	label,
	x: 0,
	y: 0,
	w: 10,
	h: 10,
	...extra,
});

const elements = [
	element(0, "button", "Back"),
	element(1, "textfield", "Address and Search", { value: "" }),
	element(2, "button", "Save"),
	element(3, "button", "Save As…"),
	element(4, "link", "Sign in to your account"),
	element(5, "textfield", "Email", { value: "" }),
	element(6, "button", "Submit"),
];

test("numbers in any common shape resolve to ids", () => {
	for (const target of ["2", "#2", "[2]", " 2 ", "element 2", "id 2"]) {
		assert.equal(resolveTarget(target, elements).element?.id, 2, target);
	}
	assert.equal(resolveTarget("99", elements).element, undefined);
});

test("labels resolve exactly before fuzzily", () => {
	assert.equal(resolveTarget("Save", elements).element?.id, 2);
	assert.equal(resolveTarget("save", elements).element?.id, 2);
	assert.equal(resolveTarget("the Save button", elements).element?.id, 2);
	assert.equal(resolveTarget("Sign in", elements).element?.id, 4);
	assert.equal(resolveTarget("Submit button", elements).element?.id, 6);
});

test("typing prefers text fields", () => {
	assert.equal(resolveTarget("email", elements, true).element?.id, 5);
	assert.equal(resolveTarget("address bar", elements, true).element?.id, 1);
});

test("unknown labels return candidates instead of guessing", () => {
	const result = resolveTarget("Preferences", elements);
	assert.equal(result.element, undefined);
});

test("observation formatting is compact", () => {
	const observation: Observation = {
		app: "Safari",
		window: "Example",
		url: "https://example.com/",
		elements: [elements[1], { ...elements[5], focused: true, value: "a@b.c" }],
		text: "Example Domain",
	};
	const text = formatObservation(observation);
	assert.match(text, /App: Safari - window "Example"/);
	assert.match(text, /\[1\] textfield "Address and Search" \(empty\)/);
	assert.match(text, /\[5\] textfield "Email" = "a@b.c" \(focused\)/);
	assert.match(text, /Text on screen:\nExample Domain/);
});

test("headings get their own lines and scroll position is shown", () => {
	const text = formatObservation({
		app: "Safari",
		elements: [element(0, "link", "More")],
		text: "# Example Domain | This domain is for examples. | More",
		scroll: 0.4,
	});
	assert.match(text, /Scroll: 40% down \(more below\)/);
	assert.match(text, /Text on screen:\n# Example Domain\nThis domain is for examples\./);
	assert.doesNotMatch(text, /\| More/);
});

test("change descriptions call out no-ops", () => {
	const before: Observation = { app: "Safari", window: "A", elements, text: "x" };
	assert.equal(describeChange(before, { ...before }), "Nothing visible changed.");
	assert.match(describeChange(before, { ...before, window: "B" }), /window is now "B"/);
});

test("risky clicks and keys need approval", () => {
	assert.equal(classifyClick(element(1, "button", "Delete account")).level, "ask");
	assert.equal(classifyClick(element(1, "button", "Buy now")).level, "ask");
	assert.equal(classifyClick(element(1, "button", "Send")).level, "ask");
	assert.equal(classifyClick(element(1, "button", "Open")).level, "allow");
	assert.equal(classifyKeys("cmd+q").level, "ask");
	assert.equal(classifyKeys("Command-Q").level, "ask");
	assert.equal(classifyKeys("cmd+t").level, "allow");
	assert.equal(normalizeKeys("Shift+Cmd+N"), "shift+cmd+n");
});

test("password and card typing is restricted", () => {
	const password = element(1, "password", "Password");
	assert.equal(classifyType(password, "hunter2", "log in").level, "block");
	assert.equal(classifyType(password, "hunter2", "log in with password hunter2").level, "ask");
	assert.equal(classifyType(element(1, "textfield", "Card"), "4111 1111 1111 1111", "pay").level, "block");
	assert.equal(classifyType(element(1, "textfield", "Name"), "Ada", "").level, "allow");
});

test("only web URLs open", () => {
	assert.equal(classifyURL("example.com").level, "allow");
	assert.equal(classifyURL("https://example.com/a?b=c").level, "allow");
	assert.equal(classifyURL("file:///etc/passwd").level, "block");
	assert.equal(classifyURL("javascript:alert(1)").level, "block");
	assert.equal(classifyURL("https://a.com\\@b.com").level, "block");
});

test("grounding answers parse in every observed shape", () => {
	assert.deepEqual(parsePoint('```json\n[\n\t{"point_2d": [829, 929], "label": "Cancel"}\n]\n```'), { x: 829, y: 929 });
	assert.deepEqual(parsePoint('{"x":829,"y":929}'), { x: 829, y: 929 });
	assert.deepEqual(parsePoint("Click(825, 926)"), { x: 825, y: 926 });
	assert.deepEqual(parsePoint('{"point_2d": 829,"y":929}'), { x: 829, y: 929 });
	assert.deepEqual(parsePoint('{"point_2d": [399,"705],"label":"x"}'), { x: 399, y: 705 });
	assert.deepEqual(parsePoint('[{"bbox_2d": [785, 900, 875, 959], "label": "Cancel"}]'), { x: 830, y: 929.5 });
	assert.equal(parsePoint("I cannot find it"), undefined);
	assert.equal(parsePoint("(1500, 20)"), undefined);
});

test("grounded points map to screen points", () => {
	const shot = { jpegBase64: "", pixelWidth: 1280, pixelHeight: 651, originX: 415, originY: 180, pointWidth: 880, pointHeight: 448 };
	assert.deepEqual(toScreen({ x: 829, y: 929 }, shot), { x: 1145, y: 596 });
});
