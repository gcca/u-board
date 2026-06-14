const std = @import("std");
const zap = @import("zap");

const ddb = @import("../../core/duckdb.zig").c;

pub const FilterKind = enum {
    text,
    number,
    boolean,
    date,
    datetime,
    fallback,
};

pub const report_row_limit: usize = 750;

pub const ReportColumn = struct { name: []const u8 };
pub const ReportCell = struct { value: []const u8 };
pub const ReportRow = struct { cells: []const ReportCell };

pub const ReportFilterColumn = struct {
    index: usize,
    name: []const u8,
    kind: FilterKind,
    op: []const u8,
    v0: []const u8,
    v1: []const u8,
    has_filter: bool,
};

pub const FilterOpOption = struct {
    value: []const u8,
    label: []const u8,
    selected: bool,
};

pub const ReportFilterColumnView = struct {
    index_str: []const u8,
    name: []const u8,
    op: []const u8,
    v0: []const u8,
    v1: []const u8,
    ops: []const FilterOpOption,
    is_text: bool,
    is_number: bool,
    is_boolean: bool,
    is_date: bool,
    is_datetime: bool,
    is_fallback: bool,
    show_v1: bool,
    is_active: bool,
};

pub const ReportActiveFilter = struct {
    label: []const u8,
    summary: []const u8,
};

pub const ReportData = struct {
    columns: []const ReportColumn,
    rows: []const ReportRow,
    row_count: usize,
};

pub fn duckdbColumnKind(column_type: c_uint) FilterKind {
    return switch (column_type) {
        ddb.DUCKDB_TYPE_BOOLEAN => .boolean,
        ddb.DUCKDB_TYPE_TINYINT,
        ddb.DUCKDB_TYPE_SMALLINT,
        ddb.DUCKDB_TYPE_INTEGER,
        ddb.DUCKDB_TYPE_BIGINT,
        ddb.DUCKDB_TYPE_UTINYINT,
        ddb.DUCKDB_TYPE_USMALLINT,
        ddb.DUCKDB_TYPE_UINTEGER,
        ddb.DUCKDB_TYPE_UBIGINT,
        ddb.DUCKDB_TYPE_FLOAT,
        ddb.DUCKDB_TYPE_DOUBLE,
        ddb.DUCKDB_TYPE_HUGEINT,
        ddb.DUCKDB_TYPE_UHUGEINT,
        ddb.DUCKDB_TYPE_DECIMAL,
        => .number,
        ddb.DUCKDB_TYPE_DATE => .date,
        ddb.DUCKDB_TYPE_TIMESTAMP,
        ddb.DUCKDB_TYPE_TIMESTAMP_S,
        ddb.DUCKDB_TYPE_TIMESTAMP_MS,
        ddb.DUCKDB_TYPE_TIMESTAMP_NS,
        ddb.DUCKDB_TYPE_TIMESTAMP_TZ,
        => .datetime,
        ddb.DUCKDB_TYPE_VARCHAR,
        ddb.DUCKDB_TYPE_ENUM,
        ddb.DUCKDB_TYPE_UUID,
        => .text,
        else => .fallback,
    };
}

pub fn defaultOpForKind(kind: FilterKind) []const u8 {
    return switch (kind) {
        .text, .fallback => "contains",
        .number => "eq",
        .boolean => "any",
        .date, .datetime => "on",
    };
}

pub fn probeReportColumns(
    conn: ddb.duckdb_connection,
    raw_query: []const u8,
    alloc: std.mem.Allocator,
) ![]ReportFilterColumn {
    const probe_sql = try std.fmt.allocPrint(alloc, "SELECT * FROM ({s}) AS _probe LIMIT 0", .{raw_query});
    defer alloc.free(probe_sql);
    const probe_z = try alloc.dupeZ(u8, probe_sql);
    defer alloc.free(probe_z);

    var result: ddb.duckdb_result = undefined;
    if (ddb.duckdb_query(conn, probe_z.ptr, &result) == ddb.DuckDBError) {
        defer ddb.duckdb_destroy_result(&result);
        return error.QueryFailed;
    }
    defer ddb.duckdb_destroy_result(&result);

    const col_count = ddb.duckdb_column_count(&result);
    var columns: std.ArrayList(ReportFilterColumn) = .{};

    for (0..col_count) |col| {
        const name_ptr = ddb.duckdb_column_name(&result, @intCast(col));
        const col_name = if (name_ptr == null) "" else try alloc.dupe(u8, std.mem.span(name_ptr));
        const kind = duckdbColumnKind(@intCast(ddb.duckdb_column_type(&result, @intCast(col))));
        const default_op = defaultOpForKind(kind);

        try columns.append(alloc, .{
            .index = col,
            .name = col_name,
            .kind = kind,
            .op = default_op,
            .v0 = "",
            .v1 = "",
            .has_filter = false,
        });
    }

    return try columns.toOwnedSlice(alloc);
}

pub fn parseFilterParams(r: zap.Request, columns: []ReportFilterColumn, alloc: std.mem.Allocator) !void {
    for (columns) |*col| {
        const op_key = try std.fmt.allocPrint(alloc, "f{d}_op", .{col.index});
        defer alloc.free(op_key);
        const v0_key = try std.fmt.allocPrint(alloc, "f{d}_v0", .{col.index});
        defer alloc.free(v0_key);
        const v1_key = try std.fmt.allocPrint(alloc, "f{d}_v1", .{col.index});
        defer alloc.free(v1_key);

        const raw_op = try r.getParamStr(alloc, op_key) orelse defaultOpForKind(col.kind);
        col.op = try normalizeOp(col.kind, raw_op, alloc);

        col.v0 = try r.getParamStr(alloc, v0_key) orelse "";
        col.v1 = try r.getParamStr(alloc, v1_key) orelse "";

        col.has_filter = evaluateHasFilter(col.*);
    }
}

pub fn buildFilteredQuery(
    alloc: std.mem.Allocator,
    raw_query: []const u8,
    columns: []const ReportFilterColumn,
) ![]const u8 {
    var where: std.ArrayList(u8) = .{};
    var first = true;

    for (columns) |col| {
        if (!col.has_filter) continue;
        const clause = try buildFilterClause(alloc, col);
        defer alloc.free(clause);

        if (!first) try where.appendSlice(alloc, " AND ");
        try where.appendSlice(alloc, clause);
        first = false;
    }

    if (where.items.len == 0) {
        return try std.fmt.allocPrint(alloc, "SELECT * FROM (SELECT * FROM ({s}) AS _sub) LIMIT {d}", .{ raw_query, report_row_limit });
    }

    return try std.fmt.allocPrint(alloc, "SELECT * FROM (SELECT * FROM ({s}) AS _sub WHERE {s}) LIMIT {d}", .{ raw_query, where.items, report_row_limit });
}

pub fn extractReportData(result: *ddb.duckdb_result, alloc: std.mem.Allocator) !ReportData {
    const col_count = ddb.duckdb_column_count(result);
    const row_count = ddb.duckdb_row_count(result);

    var columns: std.ArrayList(ReportColumn) = .{};
    for (0..col_count) |col| {
        const name_ptr = ddb.duckdb_column_name(result, @intCast(col));
        const col_name = if (name_ptr == null) "" else try alloc.dupe(u8, std.mem.span(name_ptr));
        try columns.append(alloc, .{ .name = col_name });
    }

    var rows: std.ArrayList(ReportRow) = .{};
    for (0..row_count) |row| {
        var cells: std.ArrayList(ReportCell) = .{};
        for (0..col_count) |col| {
            var cell_val: []const u8 = "";
            if (!ddb.duckdb_value_is_null(result, @intCast(col), @intCast(row))) {
                const ptr = ddb.duckdb_value_varchar(result, @intCast(col), @intCast(row));
                if (ptr != null) {
                    cell_val = try alloc.dupe(u8, std.mem.span(ptr));
                    ddb.duckdb_free(@ptrCast(ptr));
                }
            }
            try cells.append(alloc, .{ .value = cell_val });
        }
        try rows.append(alloc, .{ .cells = try cells.toOwnedSlice(alloc) });
    }

    return .{
        .columns = try columns.toOwnedSlice(alloc),
        .rows = try rows.toOwnedSlice(alloc),
        .row_count = @intCast(row_count),
    };
}

pub fn buildFilterColumnViews(
    columns: []const ReportFilterColumn,
    alloc: std.mem.Allocator,
) ![]ReportFilterColumnView {
    var views: std.ArrayList(ReportFilterColumnView) = .{};

    for (columns) |col| {
        const index_str = try std.fmt.allocPrint(alloc, "{d}", .{col.index});
        const ops = try buildOpOptions(col.kind, col.op, alloc);

        try views.append(alloc, .{
            .index_str = index_str,
            .name = col.name,
            .op = col.op,
            .v0 = col.v0,
            .v1 = col.v1,
            .ops = ops,
            .is_text = col.kind == .text,
            .is_number = col.kind == .number,
            .is_boolean = col.kind == .boolean,
            .is_date = col.kind == .date,
            .is_datetime = col.kind == .datetime,
            .is_fallback = col.kind == .fallback,
            .show_v1 = std.mem.eql(u8, col.op, "between"),
            .is_active = col.has_filter,
        });
    }

    return try views.toOwnedSlice(alloc);
}

pub fn buildActiveFilters(
    columns: []const ReportFilterColumn,
    alloc: std.mem.Allocator,
) ![]ReportActiveFilter {
    var filters: std.ArrayList(ReportActiveFilter) = .{};

    for (columns) |col| {
        if (!col.has_filter) continue;
        const summary = try filterSummary(alloc, col);
        try filters.append(alloc, .{
            .label = col.name,
            .summary = summary,
        });
    }

    return try filters.toOwnedSlice(alloc);
}

fn normalizeOp(kind: FilterKind, raw_op: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_op, " \t\r\n");
    if (!isAllowedOp(kind, trimmed)) return try alloc.dupe(u8, defaultOpForKind(kind));
    return try alloc.dupe(u8, trimmed);
}

fn isAllowedOp(kind: FilterKind, op: []const u8) bool {
    return switch (kind) {
        .text, .fallback => std.mem.eql(u8, op, "contains") or
            std.mem.eql(u8, op, "eq") or
            std.mem.eql(u8, op, "starts") or
            std.mem.eql(u8, op, "not_empty"),
        .number => std.mem.eql(u8, op, "eq") or
            std.mem.eql(u8, op, "ne") or
            std.mem.eql(u8, op, "gt") or
            std.mem.eql(u8, op, "gte") or
            std.mem.eql(u8, op, "lt") or
            std.mem.eql(u8, op, "lte") or
            std.mem.eql(u8, op, "between"),
        .boolean => std.mem.eql(u8, op, "any") or
            std.mem.eql(u8, op, "true") or
            std.mem.eql(u8, op, "false"),
        .date, .datetime => std.mem.eql(u8, op, "on") or
            std.mem.eql(u8, op, "before") or
            std.mem.eql(u8, op, "after") or
            std.mem.eql(u8, op, "between"),
    };
}

fn evaluateHasFilter(col: ReportFilterColumn) bool {
    return switch (col.kind) {
        .boolean => std.mem.eql(u8, col.op, "true") or std.mem.eql(u8, col.op, "false"),
        .text, .fallback => blk: {
            if (std.mem.eql(u8, col.op, "not_empty")) return true;
            const v0 = std.mem.trim(u8, col.v0, " \t\r\n");
            break :blk v0.len > 0;
        },
        .number => blk: {
            if (std.mem.eql(u8, col.op, "between")) {
                break :blk isValidNumber(col.v0) and isValidNumber(col.v1);
            }
            break :blk isValidNumber(col.v0);
        },
        .date => blk: {
            if (std.mem.eql(u8, col.op, "between")) {
                break :blk isValidDate(col.v0) and isValidDate(col.v1);
            }
            break :blk isValidDate(col.v0);
        },
        .datetime => blk: {
            if (std.mem.eql(u8, col.op, "between")) {
                break :blk isValidDateTime(col.v0) and isValidDateTime(col.v1);
            }
            break :blk isValidDateTime(col.v0);
        },
    };
}

fn buildFilterClause(alloc: std.mem.Allocator, col: ReportFilterColumn) ![]const u8 {
    const ident = try quoteIdent(alloc, col.name);
    defer alloc.free(ident);

    return switch (col.kind) {
        .boolean => buildBooleanClause(alloc, ident, col.op),
        .text => buildTextClause(alloc, ident, col.op, col.v0, false),
        .fallback => buildTextClause(alloc, ident, col.op, col.v0, true),
        .number => buildNumberClause(alloc, ident, col.op, col.v0, col.v1),
        .date => buildDateClause(alloc, ident, col.op, col.v0, col.v1),
        .datetime => buildDateTimeClause(alloc, ident, col.op, col.v0, col.v1),
    };
}

fn buildBooleanClause(alloc: std.mem.Allocator, ident: []const u8, op: []const u8) ![]const u8 {
    if (std.mem.eql(u8, op, "true")) return try std.fmt.allocPrint(alloc, "{s} = true", .{ident});
    if (std.mem.eql(u8, op, "false")) return try std.fmt.allocPrint(alloc, "{s} = false", .{ident});
    return error.InvalidFilter;
}

fn buildTextClause(
    alloc: std.mem.Allocator,
    ident: []const u8,
    op: []const u8,
    v0: []const u8,
    cast: bool,
) ![]const u8 {
    const col_expr = if (cast)
        try std.fmt.allocPrint(alloc, "CAST({s} AS VARCHAR)", .{ident})
    else
        try alloc.dupe(u8, ident);
    defer alloc.free(col_expr);

    if (std.mem.eql(u8, op, "not_empty")) {
        return try std.fmt.allocPrint(alloc, "({s} IS NOT NULL AND CAST({s} AS VARCHAR) != '')", .{ ident, ident });
    }

    const trimmed = std.mem.trim(u8, v0, " \t\r\n");
    const literal = try escapeSqlString(alloc, trimmed);
    defer alloc.free(literal);
    const lower_col = try std.fmt.allocPrint(alloc, "lower({s})", .{col_expr});
    defer alloc.free(lower_col);
    const lower_val = try std.fmt.allocPrint(alloc, "lower({s})", .{literal});
    defer alloc.free(lower_val);

    if (std.mem.eql(u8, op, "contains")) {
        return try std.fmt.allocPrint(alloc, "strpos({s}, {s}) > 0", .{ lower_col, lower_val });
    }
    if (std.mem.eql(u8, op, "starts")) {
        return try std.fmt.allocPrint(alloc, "startswith({s}, {s})", .{ lower_col, lower_val });
    }
    if (std.mem.eql(u8, op, "eq")) {
        return try std.fmt.allocPrint(alloc, "{s} = {s}", .{ col_expr, literal });
    }

    return error.InvalidFilter;
}

fn buildNumberClause(
    alloc: std.mem.Allocator,
    ident: []const u8,
    op: []const u8,
    v0: []const u8,
    v1: []const u8,
) ![]const u8 {
    const n0 = try parseNumberLiteral(alloc, v0);
    defer alloc.free(n0);

    if (std.mem.eql(u8, op, "eq")) return try std.fmt.allocPrint(alloc, "{s} = {s}", .{ ident, n0 });
    if (std.mem.eql(u8, op, "ne")) return try std.fmt.allocPrint(alloc, "{s} != {s}", .{ ident, n0 });
    if (std.mem.eql(u8, op, "gt")) return try std.fmt.allocPrint(alloc, "{s} > {s}", .{ ident, n0 });
    if (std.mem.eql(u8, op, "gte")) return try std.fmt.allocPrint(alloc, "{s} >= {s}", .{ ident, n0 });
    if (std.mem.eql(u8, op, "lt")) return try std.fmt.allocPrint(alloc, "{s} < {s}", .{ ident, n0 });
    if (std.mem.eql(u8, op, "lte")) return try std.fmt.allocPrint(alloc, "{s} <= {s}", .{ ident, n0 });

    if (std.mem.eql(u8, op, "between")) {
        const n1 = try parseNumberLiteral(alloc, v1);
        defer alloc.free(n1);
        return try std.fmt.allocPrint(alloc, "{s} BETWEEN {s} AND {s}", .{ ident, n0, n1 });
    }

    return error.InvalidFilter;
}

fn buildDateClause(
    alloc: std.mem.Allocator,
    ident: []const u8,
    op: []const u8,
    v0: []const u8,
    v1: []const u8,
) ![]const u8 {
    const d0 = try dateLiteral(alloc, v0);
    defer alloc.free(d0);

    if (std.mem.eql(u8, op, "on")) return try std.fmt.allocPrint(alloc, "{s} = {s}", .{ ident, d0 });
    if (std.mem.eql(u8, op, "before")) return try std.fmt.allocPrint(alloc, "{s} < {s}", .{ ident, d0 });
    if (std.mem.eql(u8, op, "after")) return try std.fmt.allocPrint(alloc, "{s} > {s}", .{ ident, d0 });

    if (std.mem.eql(u8, op, "between")) {
        const d1 = try dateLiteral(alloc, v1);
        defer alloc.free(d1);
        return try std.fmt.allocPrint(alloc, "{s} BETWEEN {s} AND {s}", .{ ident, d0, d1 });
    }

    return error.InvalidFilter;
}

fn buildDateTimeClause(
    alloc: std.mem.Allocator,
    ident: []const u8,
    op: []const u8,
    v0: []const u8,
    v1: []const u8,
) ![]const u8 {
    const t0 = try timestampLiteral(alloc, v0);
    defer alloc.free(t0);

    if (std.mem.eql(u8, op, "on")) return try std.fmt.allocPrint(alloc, "{s} = {s}", .{ ident, t0 });
    if (std.mem.eql(u8, op, "before")) return try std.fmt.allocPrint(alloc, "{s} < {s}", .{ ident, t0 });
    if (std.mem.eql(u8, op, "after")) return try std.fmt.allocPrint(alloc, "{s} > {s}", .{ ident, t0 });

    if (std.mem.eql(u8, op, "between")) {
        const t1 = try timestampLiteral(alloc, v1);
        defer alloc.free(t1);
        return try std.fmt.allocPrint(alloc, "{s} BETWEEN {s} AND {s}", .{ ident, t0, t1 });
    }

    return error.InvalidFilter;
}

fn buildOpOptions(kind: FilterKind, selected_op: []const u8, alloc: std.mem.Allocator) ![]FilterOpOption {
    const specs = switch (kind) {
        .text, .fallback => &[_]struct { []const u8, []const u8 }{
            .{ "contains", "Contiene" },
            .{ "eq", "Igual a" },
            .{ "starts", "Empieza con" },
            .{ "not_empty", "No vacío" },
        },
        .number => &[_]struct { []const u8, []const u8 }{
            .{ "eq", "=" },
            .{ "ne", "!=" },
            .{ "gt", ">" },
            .{ "gte", ">=" },
            .{ "lt", "<" },
            .{ "lte", "<=" },
            .{ "between", "Entre" },
        },
        .boolean => &[_]struct { []const u8, []const u8 }{
            .{ "any", "Cualquiera" },
            .{ "true", "Verdadero" },
            .{ "false", "Falso" },
        },
        .date, .datetime => &[_]struct { []const u8, []const u8 }{
            .{ "on", "En" },
            .{ "before", "Antes de" },
            .{ "after", "Después de" },
            .{ "between", "Entre" },
        },
    };

    var options: std.ArrayList(FilterOpOption) = .{};
    for (specs) |spec| {
        try options.append(alloc, .{
            .value = spec[0],
            .label = spec[1],
            .selected = std.mem.eql(u8, selected_op, spec[0]),
        });
    }

    return try options.toOwnedSlice(alloc);
}

fn filterSummary(alloc: std.mem.Allocator, col: ReportFilterColumn) ![]const u8 {
    if (col.kind == .boolean) {
        return try alloc.dupe(u8, opSummaryLabel(col.op));
    }
    if (std.mem.eql(u8, col.op, "not_empty")) {
        return try alloc.dupe(u8, "no vacío");
    }
    if (std.mem.eql(u8, col.op, "between")) {
        return try std.fmt.allocPrint(alloc, "entre {s} y {s}", .{ col.v0, col.v1 });
    }
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{ opSummaryLabel(col.op), col.v0 });
}

fn opSummaryLabel(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "contains")) return "contiene";
    if (std.mem.eql(u8, op, "eq")) return "igual a";
    if (std.mem.eql(u8, op, "starts")) return "empieza con";
    if (std.mem.eql(u8, op, "not_empty")) return "no vacío";
    if (std.mem.eql(u8, op, "ne")) return "distinto de";
    if (std.mem.eql(u8, op, "gt")) return "mayor que";
    if (std.mem.eql(u8, op, "gte")) return "mayor o igual que";
    if (std.mem.eql(u8, op, "lt")) return "menor que";
    if (std.mem.eql(u8, op, "lte")) return "menor o igual que";
    if (std.mem.eql(u8, op, "between")) return "entre";
    if (std.mem.eql(u8, op, "any")) return "cualquiera";
    if (std.mem.eql(u8, op, "true")) return "verdadero";
    if (std.mem.eql(u8, op, "false")) return "falso";
    if (std.mem.eql(u8, op, "on")) return "en";
    if (std.mem.eql(u8, op, "before")) return "antes de";
    if (std.mem.eql(u8, op, "after")) return "después de";
    return op;
}

fn quoteIdent(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .{};
    for (name) |c| {
        if (c == '"') {
            try escaped.appendSlice(alloc, "\"\"");
        } else {
            try escaped.append(alloc, c);
        }
    }
    return try std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped.items});
}

fn escapeSqlString(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    try out.append(alloc, '\'');
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
    return try out.toOwnedSlice(alloc);
}

fn parseNumberLiteral(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    _ = std.fmt.parseFloat(f64, trimmed) catch return error.InvalidNumber;
    return try alloc.dupe(u8, trimmed);
}

fn dateLiteral(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!isValidDate(trimmed)) return error.InvalidDate;
    const escaped = try escapeSqlString(alloc, trimmed);
    defer alloc.free(escaped);
    return try std.fmt.allocPrint(alloc, "DATE {s}", .{escaped});
}

fn timestampLiteral(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const sql_ts = try dateTimeInputToSql(alloc, trimmed);
    defer alloc.free(sql_ts);
    const escaped = try escapeSqlString(alloc, sql_ts);
    defer alloc.free(escaped);
    return try std.fmt.allocPrint(alloc, "TIMESTAMP {s}", .{escaped});
}

fn dateTimeInputToSql(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (!isValidDateTime(input)) return error.InvalidDateTime;
    if (std.mem.indexOfScalar(u8, input, 'T')) |t_pos| {
        const date_part = input[0..t_pos];
        const time_part = input[t_pos + 1 ..];
        if (time_part.len == 5) {
            return try std.fmt.allocPrint(alloc, "{s} {s}:00", .{ date_part, time_part });
        }
        return try std.fmt.allocPrint(alloc, "{s} {s}", .{ date_part, time_part });
    }
    return try alloc.dupe(u8, input);
}

fn isValidNumber(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    _ = std.fmt.parseFloat(f64, trimmed) catch return false;
    return true;
}

fn isValidDate(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != 10) return false;
    if (trimmed[4] != '-' or trimmed[7] != '-') return false;
    for (trimmed, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isValidDateTime(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, 'T')) |t_pos| {
        if (t_pos != 10) return false;
        const date_part = trimmed[0..t_pos];
        const time_part = trimmed[t_pos + 1 ..];
        if (time_part.len != 5 and time_part.len != 8) return false;
        if (time_part[2] != ':') return false;
        if (time_part.len == 8 and time_part[5] != ':') return false;
        return isValidDate(date_part) and isValidTime(time_part);
    }
    return isValidDate(trimmed);
}

fn isValidTime(raw: []const u8) bool {
    if (raw.len != 5 and raw.len != 8) return false;
    if (raw[2] != ':') return false;
    if (raw.len == 8 and raw[5] != ':') return false;
    for (raw, 0..) |c, i| {
        if (i == 2 or i == 5) continue;
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn escapeJsonString(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            '<' => try out.appendSlice(alloc, "\\u003c"),
            else => try out.append(alloc, c),
        }
    }
    return try out.toOwnedSlice(alloc);
}

pub fn serializeReportExportJson(
    alloc: std.mem.Allocator,
    columns: []const ReportColumn,
    rows: []const ReportRow,
) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    try out.appendSlice(alloc, "{\"columns\":[");
    for (columns, 0..) |col, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const esc = try escapeJsonString(alloc, col.name);
        defer alloc.free(esc);
        try out.writer(alloc).print("\"{s}\"", .{esc});
    }
    try out.appendSlice(alloc, "],\"rows\":[");
    for (rows, 0..) |row, ri| {
        if (ri > 0) try out.appendSlice(alloc, ",");
        try out.appendSlice(alloc, "[");
        for (row.cells, 0..) |cell, ci| {
            if (ci > 0) try out.appendSlice(alloc, ",");
            const esc = try escapeJsonString(alloc, cell.value);
            defer alloc.free(esc);
            try out.writer(alloc).print("\"{s}\"", .{esc});
        }
        try out.appendSlice(alloc, "]");
    }
    try out.appendSlice(alloc, "]}");
    return try out.toOwnedSlice(alloc);
}
