# Base images are pinned by digest; the tag is kept for readability.
# dart:3.13.5 (= dart:stable on 2026-10-13)
FROM dart:3.13.5@sha256:8604cbd137b6d67c24f49b916f2aa9b67d71b539576e0178bf161d831c9e344f AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY bin ./bin
RUN dart compile exe bin/relay.dart -o rhr-relay

# debian:bookworm-slim
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

COPY --from=build /app/rhr-relay /usr/local/bin/rhr-relay
ENV PORT=8123
# The relay binds loopback unless told otherwise; in a container the port is
# the network boundary. Terminate TLS in front of it: it speaks plain ws.
ENV RHR_RELAY_BIND=0.0.0.0
EXPOSE 8123
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/rhr-relay"]
