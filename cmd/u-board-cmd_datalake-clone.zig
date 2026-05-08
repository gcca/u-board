const std = @import("std");
const clap = @import("clap");

const reports_tag = "reports";

const ListReportsJob = struct {
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    owner: []const u8,
    repo: []const u8,
    output: ?std.ArrayList(u8) = null,
    err: ?anyerror = null,

    fn run(job: *ListReportsJob) void {
        job.output = buildGithubRepoReportsOutput(job.allocator, job.gh_token, job.owner, job.repo) catch |err| {
            job.err = err;
            return;
        };
    }
};

const DownloadReportsJob = struct {
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    owner: []const u8,
    datalake_dir: []const u8,
    repo: []const u8,
    err: ?anyerror = null,

    fn run(job: *DownloadReportsJob) void {
        downloadGithubRepoParquetReports(job.allocator, job.gh_token, job.owner, job.datalake_dir, job.repo) catch |err| {
            job.err = err;
            return;
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-o, --owner <str>      GitHub owner or organization. Required.
        \\-r, --repo <str>...    GitHub repository name to clone. Required; can be passed multiple times.
        \\
    );

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const owner = res.args.owner orelse {
        std.debug.print("--owner is required\n", .{});
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return error.MissingRequiredArgument;
    };

    if (res.args.repo.len == 0) {
        std.debug.print("--repo is required\n", .{});
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return error.MissingRequiredArgument;
    }
    const repos = res.args.repo;

    const datalake_dir = std.process.getEnvVarOwned(allocator, "DATALAKE_DIR") catch |err| {
        std.debug.print("EnvVar DATALAKE_DIR err: {}\n", .{err});
        return;
    };
    defer allocator.free(datalake_dir);

    std.fs.cwd().makePath(datalake_dir) catch |err| {
        std.debug.print("Create datalake dir err: {}\n", .{err});
        return;
    };

    const gh_token = std.process.getEnvVarOwned(allocator, "GH_TOKEN") catch |err| {
        std.debug.print("EnvVar GH_TOKEN err: {}\n", .{err});
        return;
    };
    defer allocator.free(gh_token);

    var list_jobs = try allocator.alloc(ListReportsJob, repos.len);
    defer allocator.free(list_jobs);
    var list_threads = try allocator.alloc(std.Thread, repos.len);
    defer allocator.free(list_threads);

    for (repos, 0..) |repo, i| {
        list_jobs[i] = .{
            .allocator = allocator,
            .gh_token = gh_token,
            .owner = owner,
            .repo = repo,
        };
        list_threads[i] = try std.Thread.spawn(.{}, ListReportsJob.run, .{&list_jobs[i]});
    }

    for (list_threads) |thread| {
        thread.join();
    }

    for (list_jobs) |*job| {
        if (job.err) |err| return err;
    }

    for (list_jobs) |*job| {
        if (job.output) |*output| {
            defer output.deinit(allocator);
            std.debug.print("{s}", .{output.items});
        }
    }

    var download_jobs = try allocator.alloc(DownloadReportsJob, repos.len);
    defer allocator.free(download_jobs);
    var download_threads = try allocator.alloc(std.Thread, repos.len);
    defer allocator.free(download_threads);

    for (repos, 0..) |repo, i| {
        download_jobs[i] = .{
            .allocator = allocator,
            .gh_token = gh_token,
            .owner = owner,
            .datalake_dir = datalake_dir,
            .repo = repo,
        };
        download_threads[i] = try std.Thread.spawn(.{}, DownloadReportsJob.run, .{&download_jobs[i]});
    }

    for (download_threads) |thread| {
        thread.join();
    }

    for (download_jobs) |*job| {
        if (job.err) |err| return err;
    }
}

fn buildGithubRepoReportsOutput(
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    owner: []const u8,
    repo: []const u8,
) !std.ArrayList(u8) {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body = try fetchGithubReleaseList(allocator, &client, gh_token, owner, repo);
    defer body.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
    defer parsed.deinit();

    const assets_value = findGithubReleaseAssets(parsed.value, reports_tag) orelse {
        std.debug.print("No release matched tag or name '{s}' for repo '{s}'\n", .{ reports_tag, repo });
        return error.GitHubReleaseNotFound;
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    for (assets_value.array.items) |asset_value| {
        if (asset_value != .object) continue;
        const asset = asset_value.object;
        const asset_name = asset.get("name") orelse continue;
        const download_url = asset.get("browser_download_url") orelse continue;
        if (asset_name != .string or download_url != .string) continue;
        try output.writer.print("{s}\n{s}\n", .{ asset_name.string, download_url.string });
    }

    return output.toArrayList();
}

fn downloadGithubRepoParquetReports(
    allocator: std.mem.Allocator,
    gh_token: []const u8,
    owner: []const u8,
    datalake_dir: []const u8,
    repo: []const u8,
) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const repo_dir = try std.fs.path.join(allocator, &[_][]const u8{ datalake_dir, repo });
    defer allocator.free(repo_dir);

    std.fs.cwd().makePath(repo_dir) catch |err| {
        std.debug.print("Create repo datalake dir err: {}\n", .{err});
        return;
    };

    var body = fetchGithubReleaseList(allocator, &client, gh_token, owner, repo) catch |err| {
        std.debug.print("Fetch release err: {}\n", .{err});
        return;
    };
    defer body.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body.items, .{}) catch |err| {
        std.debug.print("Parse JSON err: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const assets_value = findGithubReleaseAssets(parsed.value, reports_tag) orelse {
        std.debug.print("No release matched tag or name '{s}' for repo '{s}'\n", .{ reports_tag, repo });
        return;
    };

    for (assets_value.array.items) |asset_value| {
        if (asset_value != .object) continue;
        const asset = asset_value.object;
        const asset_name = asset.get("name") orelse continue;
        const asset_api_url = asset.get("url") orelse continue;
        if (asset_name != .string or asset_api_url != .string) continue;
        if (!std.mem.endsWith(u8, asset_name.string, ".parquet")) continue;

        const asset_path = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, asset_name.string });
        defer allocator.free(asset_path);

        if (std.fs.cwd().access(asset_path, .{})) |_| {
            std.debug.print("Skipping existing parquet file: {s}\n", .{asset_path});
            continue;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => {
                    std.debug.print("Check asset file err: {}\n", .{err});
                    return;
                },
            }
        }

        try downloadGithubReleaseAsset(
            allocator,
            &client,
            gh_token,
            asset_api_url.string,
            repo_dir,
            asset_name.string,
        );
    }
}

fn fetchGithubReleaseList(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    gh_token: []const u8,
    owner: []const u8,
    repo: []const u8,
) !std.ArrayList(u8) {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases",
        .{ owner, repo },
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
        std.debug.print("GitHub API returned HTTP {}\n", .{result.status});
        return error.GitHubApiRequestFailed;
    }

    return response_body.toArrayList();
}

fn findGithubReleaseAssets(release_list: std.json.Value, tag: []const u8) ?std.json.Value {
    if (release_list != .array) {
        std.debug.print("Release list response is not an array\n", .{});
        return null;
    }

    for (release_list.array.items) |release_value| {
        if (release_value != .object) continue;
        const release = release_value.object;
        const tag_name = release.get("tag_name") orelse continue;
        const name = release.get("name") orelse continue;
        if (tag_name != .string or name != .string) continue;
        if (!std.mem.eql(u8, tag_name.string, tag) and !std.mem.eql(u8, name.string, tag)) continue;

        const assets_value = release.get("assets") orelse {
            std.debug.print("No assets found in matching release\n", .{});
            return null;
        };
        if (assets_value != .array) {
            std.debug.print("Release assets field is not an array\n", .{});
            return null;
        }

        return assets_value;
    }

    return null;
}

fn downloadGithubReleaseAsset(
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
        std.debug.print("Create asset file err: {}\n", .{err});
        return;
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
        std.debug.print("Download asset err: {}\n", .{err});
        return;
    };

    if (result.status != .ok) {
        std.debug.print("GitHub asset download returned HTTP {}\n", .{result.status});
        return;
    }

    file_writer.interface.flush() catch |err| {
        std.debug.print("Flush asset file err: {}\n", .{err});
        return;
    };
}
