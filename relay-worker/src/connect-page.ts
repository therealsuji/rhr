export function connectionPage(): Response {
	const nonce = crypto.randomUUID();
	return new Response(
		`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connect to RHR</title>
<style>body{font:18px system-ui;background:#100d18;color:#f4efff;max-width:28rem;margin:12vh auto;padding:24px}h1{font-size:32px}p{line-height:1.6;color:#c5bdd6}a{color:#cbb5ff}#open{display:block;text-align:center;padding:16px;background:#7752de;color:white;text-decoration:none;border-radius:12px}code{display:block;padding:18px;background:#211a30;border-radius:12px;user-select:all} [hidden]{display:none!important}</style></head>
<body><h1>Connect to your developer</h1><p id="status">Open this page using the connection link from your developer.</p>
<section id="connection" hidden><a id="open">Open RHR</a><p>Or enter this code in RHR:</p><code id="code"></code></section>
<p>Need the player? <a href="https://github.com/therealsuji/rhr/releases" rel="noreferrer">Download RHR for Android</a>.</p>
<script nonce="${nonce}">
function readLink() {
  const section = document.getElementById('connection');
  const status = document.getElementById('status');
  section.hidden = true;
  try {
    const link = new URL(decodeURIComponent(location.hash.slice(1)));
    const code = link.searchParams.get('code');
    const relays = link.searchParams.getAll('relay');
    if (link.protocol !== 'rhr:' || link.hostname !== 'connect' || link.pathname !== '' || link.port || link.username || link.password || link.hash ||
        !/^rhr-[23456789abcdefghjkmnpqrstuvwxyz]{4}-[23456789abcdefghjkmnpqrstuvwxyz]{4}-[23456789abcdefghjkmnpqrstuvwxyz]{4}$/.test(code || '') ||
        link.searchParams.getAll('code').length !== 1 || !relays.length) throw Error();
    for (const value of relays) {
      const relay = new URL(value);
      if (!['ws:', 'wss:'].includes(relay.protocol) || !relay.hostname || relay.username || relay.password || relay.hash) throw Error();
    }
    document.getElementById('open').href = link.href;
    document.getElementById('code').textContent = code;
    status.textContent = 'Tap below on your Android phone to connect. RHR will guide any setup it needs.';
    section.hidden = false;
  } catch {
    status.textContent = 'This connection link is missing or invalid. Ask your developer for a new link, or enter their session code in RHR.';
  }
}
readLink();
addEventListener('hashchange', readLink);
</script></body></html>`,
		{
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				"Cache-Control": "no-store",
				"Referrer-Policy": "no-referrer",
				"Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
				"X-Content-Type-Options": "nosniff",
			},
		},
	);
}
