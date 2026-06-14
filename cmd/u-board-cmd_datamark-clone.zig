const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const db_path = "data/u-board.db";
const output_base = "data/datamark/source";

fn sqliteErrorMessage(db: ?*c.sqlite3) []const u8 {
    if (db) |handle| return std.mem.span(c.sqlite3_errmsg(handle));
    return "unknown sqlite error";
}

const GithubSource = struct {
    name: []u8,
    org: []u8,
    repo: []u8,
    release: []u8,
    asset: []u8,

    fn deinit(self: GithubSource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.org);
        allocator.free(self.repo);
        allocator.free(self.release);
        allocator.free(self.asset);
    }
};

const DriveSource = struct {
    name: []u8,
    fpath: []u8,

    fn deinit(self: DriveSource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.fpath);
    }
};

const GithubDownloadJob = struct {
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    source: GithubSource,
    err: ?anyerror = null,

    fn run(job: *GithubDownloadJob) void {
        cloneGithubSource(job.allocator, job.gh_token, job.source) catch |err| {
            job.err = err;
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gh_token = std.process.getEnvVarOwned(allocator, "GH_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("GH_TOKEN must be set\n", .{});
            return error.Failure;
        },
        else => return err,
    };
    defer allocator.free(gh_token);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path, &db) != c.SQLITE_OK) {
        const message = sqliteErrorMessage(db);
        if (db) |handle| _ = c.sqlite3_close(handle);
        std.debug.print("open {s} err: {s}\n", .{ db_path, message });
        return error.Failure;
    }
    defer _ = c.sqlite3_close(db.?);

    const gh_sources = try loadGithubSources(allocator, db.?);
    defer {
        for (gh_sources) |s| s.deinit(allocator);
        allocator.free(gh_sources);
    }

    const drive_sources = try loadDriveSources(allocator, db.?);
    defer {
        for (drive_sources) |s| s.deinit(allocator);
        allocator.free(drive_sources);
    }

    var jobs = try allocator.alloc(GithubDownloadJob, gh_sources.len);
    defer allocator.free(jobs);
    var threads = try allocator.alloc(std.Thread, gh_sources.len);
    defer allocator.free(threads);

    for (gh_sources, 0..) |source, i| {
        jobs[i] = .{ .allocator = allocator, .gh_token = gh_token, .source = source };
        threads[i] = try std.Thread.spawn(.{}, GithubDownloadJob.run, .{&jobs[i]});
    }

    for (threads) |thread| thread.join();

    for (jobs) |*job| {
        if (job.err) |err| {
            std.debug.print("source '{s}' err: {}\n", .{ job.source.name, err });
        }
    }

    for (drive_sources) |source| {
        cloneDriveSource(allocator, source) catch |err| {
            std.debug.print("source '{s}' err: {}\n", .{ source.name, err });
        };
    }
}

fn loadGithubSources(allocator: std.mem.Allocator, db: *c.sqlite3) ![]GithubSource {
    const sql =
        \\SELECT ds.name, gh.org, gh.repo, gh.release, gh.asset
        \\FROM datamark_source ds
        \\JOIN datamark_source_github gh ON gh.source_id = ds.id
        \\ORDER BY ds.name
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare query err: {s}\n", .{sqliteErrorMessage(db)});
        return error.SqlitePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    var list: std.ArrayList(GithubSource) = .{};
    errdefer {
        for (list.items) |s| s.deinit(allocator);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt.?, 0);
        const org_ptr = c.sqlite3_column_text(stmt.?, 1);
        const repo_ptr = c.sqlite3_column_text(stmt.?, 2);
        const release_ptr = c.sqlite3_column_text(stmt.?, 3);
        const asset_ptr = c.sqlite3_column_text(stmt.?, 4);

        if (name_ptr == null or org_ptr == null or repo_ptr == null or release_ptr == null or asset_ptr == null) continue;

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, std.mem.span(name_ptr)),
            .org = try allocator.dupe(u8, std.mem.span(org_ptr)),
            .repo = try allocator.dupe(u8, std.mem.span(repo_ptr)),
            .release = try allocator.dupe(u8, std.mem.span(release_ptr)),
            .asset = try allocator.dupe(u8, std.mem.span(asset_ptr)),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn loadDriveSources(allocator: std.mem.Allocator, db: *c.sqlite3) ![]DriveSource {
    const sql =
        \\SELECT ds.name, dr.fpath
        \\FROM datamark_source ds
        \\JOIN datamark_source_drive dr ON dr.source_id = ds.id
        \\ORDER BY ds.name
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare query err: {s}\n", .{sqliteErrorMessage(db)});
        return error.SqlitePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    var list: std.ArrayList(DriveSource) = .{};
    errdefer {
        for (list.items) |s| s.deinit(allocator);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt.?, 0);
        const fpath_ptr = c.sqlite3_column_text(stmt.?, 1);

        if (name_ptr == null or fpath_ptr == null) continue;

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, std.mem.span(name_ptr)),
            .fpath = try allocator.dupe(u8, std.mem.span(fpath_ptr)),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn cloneGithubSource(
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    source: GithubSource,
) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const out_dir = try std.fs.path.join(allocator, &[_][]const u8{ output_base, source.name });
    defer allocator.free(out_dir);

    std.fs.cwd().makePath(out_dir) catch |err| {
        std.debug.print("makePath {s} err: {}\n", .{ out_dir, err });
        return err;
    };

    var body = try fetchGithubReleaseList(allocator, &client, gh_token, source.org, source.repo);
    defer body.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
    defer parsed.deinit();

    const assets = findGithubReleaseAssets(parsed.value, source.release) orelse {
        std.debug.print("release '{s}' not found in {s}/{s}\n", .{ source.release, source.org, source.repo });
        return error.GitHubReleaseNotFound;
    };

    const asset_url = findAssetUrl(assets, source.asset) orelse {
        std.debug.print("asset '{s}' not found in release '{s}' ({s}/{s})\n", .{ source.asset, source.release, source.org, source.repo });
        return error.GitHubAssetNotFound;
    };

    const out_path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, source.asset });
    defer allocator.free(out_path);

    if (std.fs.cwd().access(out_path, .{})) |_| {
        std.debug.print("skip existing: {s}\n", .{out_path});
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try downloadGithubAsset(allocator, &client, gh_token, asset_url, out_dir, source.asset);
    std.debug.print("downloaded: {s}\n", .{out_path});
}

fn cloneDriveSource(
    allocator: std.mem.Allocator,
    source: DriveSource,
) !void {
    _ = allocator;
    std.debug.print("drive source '{s}': not implemented\n", .{source.name});
}

fn fetchGithubReleaseList(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    gh_token: []const u8,
    org: []const u8,
    repo: []const u8,
) !std.ArrayList(u8) {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases",
        .{ org, repo },
    );
    defer allocator.free(url);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{gh_token});
    defer allocator.free(auth_value);

    var headers: [3]std.http.Header = .{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{},
        .extra_headers = &headers,
        .response_writer = &response_body.writer,
    });

    if (result.status != .ok) {
        std.debug.print("GitHub API HTTP {}\n", .{result.status});
        return error.GitHubApiRequestFailed;
    }

    return response_body.toArrayList();
}

fn findGithubReleaseAssets(release_list: std.json.Value, tag: []const u8) ?std.json.Value {
    if (release_list != .array) return null;
    for (release_list.array.items) |release_value| {
        if (release_value != .object) continue;
        const release = release_value.object;
        const tag_name = release.get("tag_name") orelse continue;
        const name = release.get("name") orelse continue;
        if (tag_name != .string or name != .string) continue;
        if (!std.mem.eql(u8, tag_name.string, tag) and !std.mem.eql(u8, name.string, tag)) continue;
        const assets_value = release.get("assets") orelse return null;
        if (assets_value != .array) return null;
        return assets_value;
    }
    return null;
}

fn findAssetUrl(assets: std.json.Value, asset_name: []const u8) ?[]const u8 {
    if (assets != .array) return null;
    for (assets.array.items) |asset_value| {
        if (asset_value != .object) continue;
        const asset = asset_value.object;
        const name_val = asset.get("name") orelse continue;
        const url_val = asset.get("url") orelse continue;
        if (name_val != .string or url_val != .string) continue;
        if (!std.mem.eql(u8, name_val.string, asset_name)) continue;
        return url_val.string;
    }
    return null;
}

fn downloadGithubAsset(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    gh_token: []const u8,
    url: []const u8,
    dir: []const u8,
    filename: []const u8,
) !void {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{gh_token});
    defer allocator.free(auth_value);

    var headers: [3]std.http.Header = .{
        .{ .name = "Accept", .value = "application/octet-stream" },
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, filename });
    defer allocator.free(path);

    var file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("create file {s} err: {}\n", .{ path, err });
        return err;
    };
    defer file.close();

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{},
        .extra_headers = &headers,
        .response_writer = &file_writer.interface,
    }) catch |err| {
        std.debug.print("download {s} err: {}\n", .{ filename, err });
        return err;
    };

    if (result.status != .ok) {
        std.debug.print("GitHub asset download HTTP {}\n", .{result.status});
        return error.GitHubAssetDownloadFailed;
    }

    file_writer.interface.flush() catch |err| {
        std.debug.print("flush {s} err: {}\n", .{ path, err });
        return err;
    };
}
