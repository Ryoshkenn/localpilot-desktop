import { createServer, type Server } from "node:http";

/** Requests the test site received, so checks can verify what the agent did. */
export interface SiteLog {
	submissions: Record<string, string>[];
	visits: string[];
	deletes: number;
}

const page = (title: string, body: string) => `<!doctype html>
<html><head><meta charset="utf-8"><title>${title}</title>
<style>body{font:16px -apple-system,sans-serif;max-width:720px;margin:40px auto;padding:0 16px}
label{display:block;margin:12px 0 4px}input,select{font-size:16px;padding:6px;width:320px}
button{font-size:16px;padding:8px 18px;margin-top:16px}.product{border:1px solid #ccc;padding:12px;margin:8px 0}
.spacer{height:2400px;background:linear-gradient(#fff,#eef)}</style></head><body>${body}</body></html>`;

const products: Record<string, { name: string; price: string }> = {
	"red-mug": { name: "Red Mug", price: "$12.00" },
	"blue-mug": { name: "Blue Mug", price: "$14.50" },
	"green-teapot": { name: "Green Teapot", price: "$31.25" },
	"blue-plate": { name: "Blue Plate", price: "$9.75" },
};

export function startSite(port = 8765): Promise<{ server: Server; log: SiteLog; reset: () => void }> {
	const log: SiteLog = { submissions: [], visits: [], deletes: 0 };
	const reset = () => {
		log.submissions = [];
		log.visits = [];
		log.deletes = 0;
	};
	const server = createServer((request, response) => {
		const url = new URL(request.url ?? "/", `http://localhost:${port}`);
		log.visits.push(url.pathname);
		const send = (html: string, status = 200) => {
			response.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
			response.end(html);
		};

		if (url.pathname === "/form") {
			return send(
				page(
					"Signup form",
					`<h1>Newsletter signup</h1>
<form method="get" action="/submit">
<label for="name">Full name</label><input id="name" name="name" placeholder="Your name">
<label for="email">Email address</label><input id="email" name="email" type="email" placeholder="you@example.com">
<label for="color">Favorite color</label><select id="color" name="color"><option value="">Choose…</option><option>Red</option><option>Green</option><option>Blue</option></select>
<label><input type="checkbox" name="agree" value="yes" style="width:auto"> I agree to the terms</label>
<button type="submit">Sign up</button>
</form>`,
				),
			);
		}
		if (url.pathname === "/submit") {
			log.submissions.push(Object.fromEntries(url.searchParams));
			return send(page("Thanks", `<h1>Thanks, ${escapeHtml(url.searchParams.get("name") ?? "")}!</h1><p>You are signed up.</p>`));
		}
		if (url.pathname === "/shop") {
			const items = Object.entries(products)
				.map(([slug, product]) => `<div class="product"><a href="/product/${slug}">${product.name}</a></div>`)
				.join("");
			return send(page("Kitchen Shop", `<h1>Kitchen Shop</h1><p>Pick a product to see its price.</p>${items}`));
		}
		if (url.pathname.startsWith("/product/")) {
			const product = products[url.pathname.slice("/product/".length)];
			if (!product) return send(page("Not found", "<h1>Not found</h1>"), 404);
			return send(page(product.name, `<h1>${product.name}</h1><p>Price: <strong>${product.price}</strong></p><a href="/shop">Back to shop</a>`));
		}
		if (url.pathname === "/long") {
			return send(
				page(
					"Long article",
					`<h1>A very long article</h1><p>The secret code is at the very bottom of this page.</p><div class="spacer"></div><p>Secret code: <strong>PELICAN-42</strong></p>`,
				),
			);
		}
		if (url.pathname === "/news") {
			return send(
				page(
					"Daily Bulletin",
					`<nav><a href="/">Home</a> · <a href="/shop">Shop</a></nav><p>Updated this morning. Read time 2 minutes.</p><h1>Harbor Bridge Reopens After Repairs</h1><p>The bridge reopened to traffic on Tuesday after three months of work.</p><h2>Traffic changes</h2><p>Two lanes remain closed at night.</p>`,
				),
			);
		}
		if (url.pathname === "/account") {
			return send(
				page(
					"Account",
					`<h1>Your account</h1><form method="get" action="/delete"><button type="submit">Delete account</button></form>`,
				),
			);
		}
		if (url.pathname === "/delete") {
			log.deletes++;
			return send(page("Deleted", "<h1>Account deleted</h1>"));
		}
		send(page("Home", `<h1>LocalPilot test site</h1>`));
	});
	return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, log, reset })));
}

function escapeHtml(text: string): string {
	return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c);
}
