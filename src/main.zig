//! site: Bae, served from the app's own tree.
//!
//! A route handler. The front door calls fn "get" with the request and the
//! dispatch row (`match`). The files are not on the `main` head — an app
//! does not write `main` — so the tree is the app record's `tree` link:
//! the program record's `app` (match.program) names the head `<app>/app`.
//!
//!   an http row  {transport: "http", address: "/", prefix: true, sender: "*",
//!                 program: site, fn: "get", root?: "www", index?: "index.html"}
//!
//! Served at `/bae/`. GET/HEAD, index files, 301 for a directory without
//! its slash, 404/405, the blob's CID as the ETag.
const std = @import("std");
const cbor = @import("cbor");
const sk = @import("sk");

const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const DEFAULT_INDEX = "index.html";

pub fn main() u8 {
    return sk.main("site", run);
}

fn run(a: Allocator) !void {
    const in = try sk.input(a);
    const kind = Value.str(in.get("kind")) orelse "";
    if (!eql(u8, kind, "call")) return sk.report("site is a route handler: it is called (fn \"get\"), never stepped");
    const func = Value.str(in.get("fn")) orelse "";
    if (!eql(u8, func, "get")) return sk.report("unknown fn (site answers \"get\")");
    const req = cbor.decode(a, Value.bytesOf(in.get("arg")) orelse "") catch return sk.report("the argument is not dag-cbor");
    return sk.answer(a, try serve(a, req));
}

const Answer = struct {
    status: u64,
    type: []const u8 = "text/plain; charset=utf-8",
    body: []const u8 = "",
    etag: ?[]const u8 = null,
    location: ?[]const u8 = null,
    allow: bool = false,

    fn value(r: Answer, a: Allocator) !Value {
        var h = cbor.MapBuilder.init(a);
        if (r.etag) |e| try h.put("etag", cbor.string(e));
        if (r.location) |l| try h.put("location", cbor.string(l));
        if (r.allow) try h.put("allow", cbor.string("GET, HEAD"));
        var m = cbor.MapBuilder.init(a);
        try m.put("status", cbor.int(r.status));
        try m.put("type", cbor.string(r.type));
        try m.put("body", .{ .bytes = r.body });
        try m.put("headers", h.value());
        return m.value();
    }
};

fn notFound(head: bool) Answer {
    return .{ .status = 404, .body = if (head) "" else "not found\n" };
}

fn serve(a: Allocator, req: Value) !Value {
    const method = Value.str(req.get("method")) orelse "GET";
    const head = eql(u8, method, "HEAD");
    if (!head and !eql(u8, method, "GET")) {
        const r = Answer{ .status = 405, .body = "method not allowed (GET, HEAD)\n", .allow = true };
        return r.value(a);
    }
    const match: Value = req.get("match") orelse .null;
    const route = Value.str(req.get("route")) orelse Value.str(req.get("path")) orelse "/";
    const rest = restOf(route, prefixOf(match)) orelse return notFound(head).value(a);
    const root = Value.str(match.get("root")) orelse "www";
    const index = Value.str(match.get("index")) orelse DEFAULT_INDEX;
    const p = (try resolvePath(a, root, rest)) orelse return notFound(head).value(a);
    const tree = (try appTree(a, match)) orelse return notFound(head).value(a);

    var e = (try lookup(a, tree, p.segs)) orelse return notFound(head).value(a);
    var name = if (p.segs.len > 0) p.segs[p.segs.len - 1] else "";
    if (isDir(e.mode)) {
        const bare_prefix = rest.len == 0 and prefixOf(match) != null and !std.mem.endsWith(u8, route, "/");
        if (!p.dir or bare_prefix) {
            // The directory without its `/`. `query` already includes the '?', as the front door passes it.
            const path = Value.str(req.get("path")) orelse route;
            const query = Value.str(req.get("query")) orelse "";
            const loc = try std.mem.concat(a, u8, &.{ path, "/", query });
            return (Answer{ .status = 301, .location = loc }).value(a);
        }
        const ix = (try resolvePath(a, "", index)) orelse return notFound(head).value(a);
        e = (try lookup(a, e.cid, ix.segs)) orelse return notFound(head).value(a);
        name = index;
    } else if (rest.len > 0 and p.dir) return notFound(head).value(a);
    if (!isFile(e.mode)) return notFound(head).value(a);

    const etag = try std.mem.concat(a, u8, &.{ "\"", try cbor.cidm.format(a, e.cid), "\"" });
    const ctype = contentType(name);
    if (matches(etag, headerOf(req.get("headers"), "if-none-match"))) {
        return (Answer{ .status = 304, .type = ctype, .etag = etag }).value(a);
    }
    const bytes = try sk.getBytes(a, e.cid);
    const body = gitBlob(bytes) orelse return sk.report("the tree names an object that is not a git blob");
    return (Answer{ .status = 200, .type = ctype, .body = if (head) "" else body, .etag = etag }).value(a);
}

/// The app record's tree: match.program → the program record's `app` → head `<app>/app` → `tree`.
fn appTree(a: Allocator, match: Value) !?[]const u8 {
    const prog = Value.cidOf(match.get("program")) orelse return sk.report("the row names no program");
    const rec = try sk.get(a, prog);
    const name = Value.str(rec.get("app")) orelse return sk.report("the program record names no app");
    const head_name = try std.fmt.allocPrint(a, "{s}/app", .{name});
    const root = (try sk.head(a, head_name)) orelse return null;
    const app = try sk.get(a, root);
    if (!eql(u8, Value.str(app.get("kind")) orelse "", "app")) return sk.report("the app head is not an app record");
    return Value.cidOf(app.get("tree"));
}

fn headerOf(m: ?Value, name: []const u8) ?[]const u8 {
    const v = m orelse return null;
    if (v != .map) return null;
    for (v.map) |x| if (std.ascii.eqlIgnoreCase(x.key, name)) return Value.str(x.value);
    return null;
}

pub fn matches(etag: []const u8, header: ?[]const u8) bool {
    const h = header orelse return false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |raw| {
        var t = std.mem.trim(u8, raw, " \t");
        if (eql(u8, t, "*")) return true;
        if (std.mem.startsWith(u8, t, "W/")) t = t[2..];
        if (eql(u8, t, etag)) return true;
    }
    return false;
}

pub fn prefixOf(match: Value) ?[]const u8 {
    const p = match.get("prefix") orelse return null;
    if (p == .bool and p.bool) return Value.str(match.get("address"));
    return null;
}

pub fn restOf(route: []const u8, prefix: ?[]const u8) ?[]const u8 {
    const p = prefix orelse return "";
    if (!std.mem.startsWith(u8, route, p)) return null;
    const rest = route[p.len..];
    if (rest.len > 0 and !std.mem.endsWith(u8, p, "/") and rest[0] != '/') return null;
    return rest;
}

pub const Resolved = struct {
    segs: []const []const u8,
    dir: bool,
};

pub fn resolvePath(a: Allocator, root: []const u8, rest: []const u8) !?Resolved {
    var segs: std.ArrayList([]const u8) = .empty;
    if (!try appendSegments(a, &segs, root, false)) return null;
    if (!try appendSegments(a, &segs, rest, true)) return null;
    const dir = rest.len == 0 or rest[rest.len - 1] == '/';
    return .{ .segs = segs.items, .dir = dir };
}

fn appendSegments(a: Allocator, segs: *std.ArrayList([]const u8), path: []const u8, decode: bool) !bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |raw| {
        const seg = if (decode) (try percentDecode(a, raw)) orelse return false else raw;
        if (seg.len == 0 or eql(u8, seg, ".")) continue;
        if (eql(u8, seg, "..")) return false;
        if (std.mem.indexOfAny(u8, seg, "/\x00") != null) return false;
        try segs.append(a, seg);
    }
    return true;
}

pub fn percentDecode(a: Allocator, s: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    const out = try a.alloc(u8, s.len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len) : (o += 1) {
        if (s[i] != '%') {
            out[o] = s[i];
            i += 1;
            continue;
        }
        if (i + 3 > s.len) return null;
        out[o] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
        i += 3;
    }
    return out[0..o];
}

fn isDir(mode: []const u8) bool {
    return eql(u8, mode, "40000");
}

fn isFile(mode: []const u8) bool {
    return eql(u8, mode, "100644") or eql(u8, mode, "100755");
}

fn lookup(a: Allocator, tree: []const u8, segs: []const []const u8) !?sk.TreeEntry {
    var e = sk.TreeEntry{ .mode = "40000", .name = "", .cid = tree };
    for (segs) |seg| {
        if (!isDir(e.mode)) return null;
        e = for (try sk.readTree(a, e.cid)) |x| {
            if (eql(u8, x.name, seg)) break x;
        } else return null;
    }
    return e;
}

fn gitBlob(obj: []const u8) ?[]const u8 {
    const nul = std.mem.indexOfScalar(u8, obj, 0) orelse return null;
    const h = obj[0..nul];
    if (!std.mem.startsWith(u8, h, "blob ")) return null;
    const n = std.fmt.parseInt(usize, h[5..], 10) catch return null;
    if (n != obj.len - nul - 1) return null;
    return obj[nul + 1 ..];
}

const types = [_][2][]const u8{
    .{ "html", "text/html; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "js", "text/javascript; charset=utf-8" },
    .{ "json", "application/json" },
    .{ "svg", "image/svg+xml" },
    .{ "png", "image/png" },
    .{ "woff2", "font/woff2" },
};

pub fn contentType(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    if (dot == 0) return "application/octet-stream";
    const ext = name[dot + 1 ..];
    for (types) |x| if (std.ascii.eqlIgnoreCase(x[0], ext)) return x[1];
    return "application/octet-stream";
}

const testing = std.testing;

fn expectSegs(want: []const []const u8, dir: bool, got: ?Resolved) !void {
    const r = got orelse return error.TestExpectedResolved;
    try testing.expectEqual(want.len, r.segs.len);
    for (want, r.segs) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(dir, r.dir);
}

test "a page path stays under www" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectSegs(&.{"www"}, true, try resolvePath(a, "www", ""));
    try expectSegs(&.{"www"}, true, try resolvePath(a, "www", "/"));
    try expectSegs(&.{ "www", "index.html" }, false, try resolvePath(a, "www", "/index.html"));
    try testing.expect(try resolvePath(a, "www", "/../etc/app.json") == null);
    try testing.expect(try resolvePath(a, "www", "/%2e%2e/x") == null);
}

test "the served prefix is /bae/" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = cbor.MapBuilder.init(a);
    try m.put("address", cbor.string("/bae/"));
    try m.put("prefix", .{ .bool = true });
    const match = m.value();
    try testing.expectEqualStrings("/bae/", prefixOf(match).?);
    try testing.expectEqualStrings("", restOf("/bae/", prefixOf(match)).?);
    try testing.expectEqualStrings("index.html", restOf("/bae/index.html", prefixOf(match)).?);
    try testing.expect(restOf("/baebox", prefixOf(match)) == null);
}
