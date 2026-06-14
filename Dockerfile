# syntax=docker/dockerfile:1.7

ARG DEBIAN_VERSION=bookworm-slim
ARG DEPS_IMAGE=ghcr.io/gcca/u-board-deps:latest

FROM ${DEPS_IMAGE} AS deps

FROM deps AS build

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY src ./src
COPY cmd ./cmd
COPY db ./db

RUN zig build -Doptimize=ReleaseFast -Dduckdb-prefix=/usr/local

RUN mkdir -p zig-out/lib \
    && find .zig-cache -name 'libfacil.io.so' -exec cp '{}' zig-out/lib/ \; \
    && test -f zig-out/lib/libfacil.io.so

FROM debian:${DEBIAN_VERSION} AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /src/zig-out/bin/u-board /usr/local/bin/u-board
COPY --from=build /src/zig-out/bin/u-board-cmd_create-user /usr/local/bin/u-board-cmd_create-user
COPY --from=build /src/zig-out/lib/libfacil.io.so /usr/local/lib/libfacil.io.so
COPY --from=build /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so

RUN ldconfig && mkdir -p /app/db

ENV DATABASE_URL=sqlite:db/u-board.db

EXPOSE 5561

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fs http://127.0.0.1:5561/u-board/healthcheck >/dev/null || exit 1

CMD ["/usr/local/bin/u-board"]
