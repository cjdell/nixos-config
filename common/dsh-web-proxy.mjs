#!/usr/bin/env node
// dsh-web-proxy — a very small HTTP reverse proxy for the dsh web GUI.
//
// The dsh web server binds 127.0.0.1 only (it refuses --host 0.0.0.0), and its
// /api trust fence 403s requests whose Host/Origin headers name anything other
// than a loopback host, so the GUI cannot be used from other machines. This
// proxy listens on all interfaces, forwards each request to the upstream over
// loopback, and rewrites the Host (and Origin) headers to the upstream's
// loopback authority, so the app believes the request is local. Response bytes
// are forwarded untouched, which keeps chunked bodies, SSE streams and
// WebSocket upgrades intact.
//
// Each client connection is one-shot: the forwarded request carries
// "connection: close", so the upstream answers "connection: close" and the
// browser opens a fresh connection per request. That also guarantees the Host
// rewrite applies to EVERY request — a reused keep-alive connection's later
// requests would still carry the client's original Host and 403.
//
// Zero dependencies: node:net only. Started/stopped by `dsh-web proxy`.
//
//   DSH_WEB_PROXY_PORT  listen port      (default 30800)
//   DSH_WEB_PROXY_BIND  listen address   (default 0.0.0.0)
//   DSH_WEB_UPSTREAM    target host:port (default 127.0.0.1:3080)

import net from "node:net";

const port = Number(process.env.DSH_WEB_PROXY_PORT ?? 30800);
const bindHost = process.env.DSH_WEB_PROXY_BIND ?? "0.0.0.0";
const [upHost, upPort] = (process.env.DSH_WEB_UPSTREAM ?? "127.0.0.1:3080").split(":");
const upHostHeader = `${upHost}:${upPort}`;
const upOrigin = `http://${upHostHeader}`;
const HEAD_LIMIT = 1024 * 1024; // a request head is far smaller than 1 MiB

// Rewrite one request head (first line + headers, CRLF-terminated) for the
// upstream. latin1 keeps every head byte intact.
function rewriteHead(head) {
	const lines = head.toString("latin1").split("\r\n");
	const isUpgrade = lines.some((l) => /^upgrade:/i.test(l));
	const out = [];
	let hasConnection = false;
	for (const line of lines) {
		if (/^host:/i.test(line)) out.push(`host: ${upHostHeader}`);
		else if (/^origin:/i.test(line)) out.push(`origin: ${upOrigin}`);
		else if (/^connection:/i.test(line)) {
			hasConnection = true;
			// WebSocket upgrades need their own "Connection: Upgrade" — keep it.
			out.push(isUpgrade ? line : "connection: close");
		} else if (/^proxy-connection:/i.test(line)) {
			// drop
		} else out.push(line);
	}
	if (!isUpgrade && !hasConnection) out.splice(out.indexOf(""), 0, "connection: close");
	return Buffer.from(out.join("\r\n"), "latin1");
}

const server = net.createServer((client) => {
	let headBuf = null; // request bytes until the head is complete
	let headDone = false;
	let dead = false; // stop handling this client
	let upstream = null;
	let sawUpstreamData = false;

	client.on("error", () => upstream?.destroy());
	client.on("close", () => upstream?.destroy());

	client.on("data", (chunk) => {
		if (dead) return;
		if (headDone) {
			upstream?.write(chunk);
			return;
		}
		headBuf = headBuf === null ? chunk : Buffer.concat([headBuf, chunk]);
		const idx = headBuf.indexOf("\r\n\r\n");
		if (idx === -1) {
			if (headBuf.length > HEAD_LIMIT) {
				dead = true;
				client.end(
					"HTTP/1.1 431 Request Header Fields Too Large\r\n" +
						"Content-Length: 0\r\n" +
						"Connection: close\r\n\r\n",
				);
			}
			return;
		}
		headDone = true;
		const rawHead = headBuf.subarray(0, idx + 4);
		const rest = headBuf.subarray(idx + 4);
		headBuf = null;

		upstream = net.connect(Number(upPort), upHost);
		upstream.on("data", (d) => {
			sawUpstreamData = true;
			client.write(d);
		});
		upstream.on("error", (err) => {
			if (!sawUpstreamData && !dead) {
				// No bytes from the upstream yet: answer a real 502.
				dead = true;
				const body = `dsh-web-proxy: upstream ${upHostHeader} unreachable (${err.code ?? err.message})\n`;
				client.end(
					`HTTP/1.1 502 Bad Gateway\r\n` +
						`Content-Type: text/plain\r\n` +
						`Content-Length: ${Buffer.byteLength(body)}\r\n` +
						`Connection: close\r\n\r\n` +
						body,
				);
			}
			upstream.destroy();
			client.destroy();
		});
		upstream.on("close", () => {
			// The upstream always answers connection: close for us; end the
			// client gracefully so queued response bytes flush before FIN.
			if (!dead) client.end();
		});
		upstream.write(rewriteHead(rawHead));
		if (rest.length) upstream.write(rest);
	});
});

server.on("error", (err) => {
	console.error(`dsh-web-proxy: cannot listen on ${bindHost}:${port}: ${err.message}`);
	process.exit(1);
});

server.listen(port, bindHost, () => {
	console.log(`dsh-web-proxy: listening on ${bindHost}:${port} -> ${upHostHeader}`);
});
