# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2026-06-20]

### Added
- Datamark Sources management in the admin interface:
  - Full CRUD for datamark sources with support for `github` (org, repo, release, asset) and `drive` (fpath) kinds.
  - Dedicated list and form templates with dynamic field visibility.
  - Integrated with HTMX for in-page interactions.
- Datamark Views now link to a `datamark_source` via `source_id` (integer FK with cascade delete).
- Updated database fixtures with additional sample data for the new tables.

### Changed
- Database schema and the single migration (`20260508130128_01_init.sql`) extended with `datamark_source`, `datamark_source_github`, `datamark_source_drive`, and updated `datamark_view` (added `source_id`).
- Admin navigation and templates updated to surface Datamark Sources alongside Datamark Views.
- Admin routes (`handling/admin/routes.zig`) significantly expanded with source and view handlers.

### Fixed
- Memory leak in `src/u-board/core/conf.zig` related to `DATABASE_URL` ownership tracking and cleanup.

**Commits**: [`6933a06`](https://github.com/gcca/u-board/commit/6933a06), [`dbd9120`](https://github.com/gcca/u-board/commit/dbd9120), [`0595c01`](https://github.com/gcca/u-board/commit/0595c01), [`e9663d2`](https://github.com/gcca/u-board/commit/e9663d2)

## [2026-06-18]

### Added
- Admin Datamark Views module:
  - List, form (create/edit), save, and remove endpoints.
  - HTMX-powered UI fragments under `/u-board/admin/datamark-views/*`.
  - Supporting query helpers and form handling in admin routes.
- CI/CD and deployment:
  - GitHub Actions: `deps.yaml`, `fly-deploy.yml`; updated `package.yaml`.
  - Fly.io configuration (`fly.toml`).
  - Multi-stage Docker support (`Dockerfile.deps`, updated `Dockerfile`).
- Additional sample data fixtures.

### Changed
- Database migration and schema updated to introduce the initial `datamark_view` table (subsequently refined).
- Large expansion of admin routes and templates.
- Minor dashboard template tweaks.

**Commits**: [`df51b58`](https://github.com/gcca/u-board/commit/df51b58), [`ed4de6e`](https://github.com/gcca/u-board/commit/ed4de6e), [`eaf0031`](https://github.com/gcca/u-board/commit/eaf0031)

## [2026-06-14]

### Added
- Additional daisyUI theme options (wireframe, cmyk, autumn, business, acid, lemonade, caramellatte, abyss, silk, etc.) to the theme switcher in admin, root, and user dashboard sidebars.

### Changed
- Architecture consistency pass:
  - Auth routes now use the same `Middleware(.{}, ...)` + `Scope` pattern as other route groups.
  - Removed module-level `context` globals and manual DB/arena management from auth handlers.
  - `http.zig` updated to support zero-middleware case and adjusted `getPost` signature to pass `Scope`.
- Minor import ordering in `src/main.zig`.

**Commits**: [`99c762e`](https://github.com/gcca/u-board/commit/99c762e), [`06518c6`](https://github.com/gcca/u-board/commit/06518c6), [`e09e99c`](https://github.com/gcca/u-board/commit/e09e99c)

## [2026-05-08]

### Added
- Initial release of **U-Board** — a role-based Zig web application built with `zap`.
  - **Authentication**:
    - Username/password sign-in with Argon2 hashing.
    - "Sign in with Office 365" using Azure AD device code flow (polling UI + `/validate` endpoint).
  - **Authorization & Roles** (`Role` enum: root=0, admin=1, staff=2, user=3):
    - Middleware decorators: `LogInRequired`, `RoleRequired`.
    - Role-specific route groups and redirects (`/u-board/main`).
  - **Dashboards and features**:
    - Admin: dashboard stats, users list (htmx), (foundational UI).
    - Root: dashboard, all users list, lakehouse (datalake) schema browser (list + table details).
    - User: dashboard stats, raw files view (static pipeline listing).
  - **Technical foundation**:
    - Middleware orchestrator + per-request `ArenaAllocator` + scoped SQLite connections (`core/http.zig`, `Scope`).
    - Mustache templates + daisyUI (cupcake) + htmx v2 + Tailwind.
    - Shared utilities (timestamps, initials, Role enum).
    - Shortcuts and helpers for routes/sessions.
  - **Database**:
    - SQLite with initial schema + migration for `auth_user`, `auth_session`, `auth_app_provider`.
    - Fixtures and `db/schema.sql`.
  - **Tooling & Ops**:
    - CLI commands: `u-board-cmd_create-user`, `u-board-cmd_datalake-init`, `u-board-cmd_datalake-clone`.
    - Zig build system (`build.zig`, `build.zig.zon` pinning zap + clap).
    - Docker, docker-compose.
    - Initial GitHub Actions packaging workflow.
    - Fly.io-ready configuration scaffolding.

**Commit**: [`a362d0d`](https://github.com/gcca/u-board/commit/a362d0d) ("U-Board 🚀")

## Notes

- Development to date has been via direct commits on `master`. No pull requests or issues were present in the repository at the time of writing this changelog.
- The project uses a single migration file; schema changes have been applied by editing it during early development.
