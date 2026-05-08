FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.15.2
ARG DUCKDB_VERSION=v1.5.2
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl tar xz-utils ca-certificates unzip libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        amd64) ZIG_ARCH="x86_64" ;; \
        arm64) ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/zig \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt/zig --strip-components=1

RUN case "${TARGETARCH}" in \
        amd64) DUCKDB_ARCH="amd64" ;; \
        arm64) DUCKDB_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/libduckdb-linux-${DUCKDB_ARCH}.zip" \
       -o /tmp/libduckdb.zip \
    && unzip /tmp/libduckdb.zip -d /tmp/duckdb \
    && cp /tmp/duckdb/libduckdb.so /usr/local/lib/ \
    && cp /tmp/duckdb/duckdb.h /tmp/duckdb/duckdb.hpp /usr/local/include/ \
    && ldconfig \
    && rm -rf /tmp/libduckdb.zip /tmp/duckdb

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src
COPY cmd ./cmd
COPY db ./db

RUN --mount=type=cache,target=/root/.cache/zig \
    zig build -Doptimize=ReleaseFast -Dduckdb-prefix=/usr/local

RUN mkdir -p zig-out/lib \
    && find .zig-cache -name 'libfacil.io.so' -exec cp '{}' zig-out/lib/ \; \
    && test -f zig-out/lib/libfacil.io.so

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/zig-out/bin/u-board /usr/local/bin/u-board
COPY --from=build /app/zig-out/bin/u-board-cmd_create-user /usr/local/bin/u-board-cmd_create-user
COPY --from=build /app/zig-out/lib/libfacil.io.so /usr/local/lib/libfacil.io.so
COPY --from=build /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so

RUN ldconfig && mkdir -p /app/db

ENV DATABASE_URL=sqlite:db/u-board.db

EXPOSE 5561

CMD ["/usr/local/bin/u-board"]
