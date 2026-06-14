# u-board

Internal dashboard server written in Zig. Serves role-scoped web UIs backed for user/session data and analytics/datamark reports. All UI copy is Spanish (`lang="es"`).

## System Requirements

- **Zig** 0.15.2+
- **SQLite3** (system library)
- **dbmate** for database migrations

## Build

```sh
zig build
```

Run tests:

```sh
zig build test
```

## First-Time Setup

### 1. Create the database

```sh
mkdir -p data
DATABASE_URL="sqlite:data/u-board.db" dbmate up
```

Seed sample data (optional):

```sh
sqlite3 data/u-board.db < db/fixtures/sample-data.sql
```

### 2. Create an admin user

```sh
DATABASE_URL="sqlite:data/u-board.db" \
  ./zig-out/bin/u-board-cmd_create-user -u admin -p secret
```

### 3. Start the server

```sh
DATABASE_URL="sqlite:data/u-board.db" ./zig-out/bin/u-board
```

Server listens on **port 5561**. Navigate to `http://localhost:5561/u-board/auth/signin`.

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | `sqlite:data/u-board.db` | SQLite database path |

## Database Migrations

Always create migrations via dbmate, never hand-create timestamped files:

```sh
DATABASE_URL="sqlite:data/u-board.db" dbmate new {migration_name}
DATABASE_URL="sqlite:data/u-board.db" dbmate up
DATABASE_URL="sqlite:data/u-board.db" dbmate dump   # keeps db/schema.sql in sync
```

## Architecture Overview

### Middleware Chain

Every route handler is wrapped in `Middleware(middlewares, handler)` which manages per-request lifecycle: arena allocation, cookie parsing, SQLite connection open/close. Handlers receive a `Scope`:

```zig
pub const Scope = struct {
    context: *Context,        // global app context
    db: *sqlite3,             // per-request DB connection
    arena: *ArenaAllocator,   // per-request allocator; use s.arena.allocator()
};
```

Protected routes use the `RoleRoute` shortcut:

```zig
RoleRoute(.admin, handler)
// expands to: Middleware(.{ LogInRequired(), RoleRequired(.admin) }, handler)
```

Auth routes use `Middleware(.{}, handler)` — scope is provided but no auth is checked.

### Role System

Roles are stored as `INTEGER` in SQLite and typed as `uboard.utils.Role`:

| Integer | Enum | Route prefix | Display label |
|---|---|---|---|
| 0 | `.root` | `/u-board/root` | root |
| 1 | `.admin` | `/u-board/admin` | administrador |
| 2 | `.staff` | — | staff |
| 3 | `.user` | `/u-board/user` | usuario |

After sign-in, `/u-board/main` reads the session role and redirects to the matching prefix.

### Templates

All UI uses Mustache templates with daisyUI v5 + Tailwind (browser build) + htmx v2. Templates live alongside their route handler under `handling/{role}/template/`. Comments use `{{! ... }}` syntax.

## Binaries Built

| Binary | Purpose |
|---|---|
| `u-board` | HTTP server |
| `u-board-cmd_create-user` | Create a user in the database |
| `u-board-cmd_datamark-clone` | Download files |
| `u-board-cmd_datamark-flush` | Load files into `data/dmark.db` |
