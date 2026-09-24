FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin ./bin
RUN dart compile exe bin/relay.dart -o /out/rhr-relay

FROM debian:bookworm-slim

COPY --from=build /out/rhr-relay /usr/local/bin/rhr-relay
ENV PORT=8123
EXPOSE 8123
ENTRYPOINT ["/usr/local/bin/rhr-relay"]
