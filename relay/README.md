# Self-hosted relay

This is the single-instance Dart relay used for private deployments. It keeps
active sessions in memory and intentionally has no database. Restarting it
drops active WebSockets; both rhr ends reconnect and can pair again with the
same code.

The relay forwards text signaling and control messages only. Binary tunnel
payloads are rejected because VM-service and asset traffic belongs on the
direct WebRTC data channel.

Build and run it with Docker:

```bash
cd relay
docker build -t rhr-relay .
docker run --rm -p 8123:8123 -e PORT=8123 rhr-relay
```

Put it behind a TLS reverse proxy before using it from a phone or an internet
connection. The client URL must be `wss://…`; the plain `ws://` form is only for
trusted local development. A reverse proxy should forward WebSocket upgrades
and expose `/healthz` for its health check.

Use the resulting URL with the product flow:

```bash
rhr run --relay wss://relay.example.com
```

Or set `relay: wss://relay.example.com` in `.rhr.yaml`. Keep the relay to one
instance until session routing or shared state is added; the current process
owns its session map and cached device-info messages.
