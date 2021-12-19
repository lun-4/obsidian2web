const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

const StringList = std.ArrayList(u8);
const BuildFile = @import("build_file.zig").BuildFile;

const PageBuildStatus = enum {
    Unbuilt,
    Built,
    Error,
};

const Page = struct {
    filesystem_path: []const u8,
    title: []const u8,
    status: PageBuildStatus = .Unbuilt,
    html_path: ?[]const u8 = null,
    web_path: ?[]const u8 = null,
    errors: ?[]const u8 = null,
};

const PageMap = std.StringHashMap(Page);

// article on path a/b/c/d/e.md is mapped as "e" in this title map.
const TitleMap = std.StringHashMap([]const u8);

const PageFile = union(enum) {
    dir: PageFolder,
    file: []const u8,
};

const PageFolder = std.StringHashMap(PageFile);

/// recursively deinitialize a PageFolder
fn deinitPageFolder(folder: *PageFolder) void {
    var folder_it = folder.iterator();
    while (folder_it.next()) |entry| {
        var child = entry.value_ptr;
        switch (child.*) {
            .dir => |*child_folder| deinitPageFolder(child_folder),
            .file => {},
        }
    }
    folder.deinit();
}

const PageTree = struct {
    allocator: std.mem.Allocator,
    root: PageFolder,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .root = PageFolder.init(allocator),
        };
    }
    pub fn deinit(self: *Self) void {
        deinitPageFolder(&self.root);
    }
    pub fn addPage(self: *Self, fspath: []const u8) !void {
        const total_seps = std.mem.count(u8, fspath, &[_]u8{std.fs.path.sep});
        var path_it = std.mem.split(u8, fspath, &[_]u8{std.fs.path.sep});

        var current_page: ?*PageFolder = &self.root;
        var idx: usize = 0;
        while (true) : (idx += 1) {
            const maybe_path_component = path_it.next();
            if (maybe_path_component == null) break;
            const path_component = maybe_path_component.?;

            if (current_page.?.getPtr(path_component)) |child_page| {
                current_page = &child_page.dir;
            } else {

                // if last component, create file (and set current_page to null), else, create folder
                if (idx == total_seps) {
                    try current_page.?.put(path_component, .{ .file = fspath });
                } else {
                    try current_page.?.put(path_component, .{ .dir = PageFolder.init(self.allocator) });
                }
            }
        }
    }
};

fn addFilePage(
    pages: *PageMap,
    titles: *TitleMap,
    tree: *PageTree,
    local_path: []const u8,
    fspath: []const u8,
) !void {
    if (!std.mem.endsWith(u8, local_path, ".md")) return;
    std.log.info("new page: local='{s}' fs='{s}'", .{ local_path, fspath });

    const title_raw = std.fs.path.basename(local_path);
    const title = title_raw[0 .. title_raw.len - 3];
    std.log.info("  title='{s}'", .{title});
    try titles.put(title, local_path);
    try pages.put(local_path, Page{ .filesystem_path = fspath, .title = title });
    try tree.addPage(local_path);
}
const StringBuffer = std.ArrayList(u8);

const ProcessorContext = struct {
    titles: *TitleMap,
    pages: *PageMap,
    captures: []?libpcre.Capture,
    file_contents: []const u8,
};

const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn handle(self: *Self, ctx: ProcessorContext, result: *StringBuffer) !void {
        _ = self;
        const match = ctx.captures[0].?;
        const check = ctx.file_contents[match.start..match.end];
        try result.writer().print("<code>{s}</code>", .{check});
    }
};

const LinkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn handle(self: *Self, ctx: ProcessorContext, result: *StringBuffer) !void {
        _ = self;
        const match = ctx.captures[0].?;

        std.log.info("match {} {}", .{ match.start, match.end });
        const referenced_title = ctx.file_contents[match.start + 2 .. match.end - 2];
        std.log.info("link to '{s}'", .{referenced_title});

        // TODO strict_links support goes here
        var page_local_path = ctx.titles.get(referenced_title).?;
        var page = ctx.pages.get(page_local_path).?;

        try result.writer().print("<a href=\"{s}.html\">{s}</a>", .{ page.web_path, referenced_title });
    }
};

const Paths = struct { web_path: []const u8, output_path: []const u8, html_path: []const u8 };

pub fn parsePaths(local_path: []const u8, output_path_buffer: []u8, html_path_buffer: []u8) !Paths {
    var fba = std.heap.FixedBufferAllocator{ .buffer = output_path_buffer, .end_index = 0 };
    var fixed_alloc = fba.allocator();
    // TODO have simple mem.join with slashes since its the web lmao
    const output_path = try std.fs.path.join(fixed_alloc, &[_][]const u8{ "public", local_path });
    const web_path_raw = local_path[0 .. local_path.len - 3];

    const offset = std.mem.replacementSize(u8, output_path, ".md", ".html");
    _ = std.mem.replace(u8, output_path, ".md", ".html", html_path_buffer);
    const html_path = html_path_buffer[0..offset];

    var result = StringList.init(fixed_alloc);
    defer result.deinit();

    for (web_path_raw) |char| {
        switch (char) {
            '$' => try result.appendSlice("%24"),
            '&' => try result.appendSlice("%26"),
            '+' => try result.appendSlice("%2B"),
            ',' => try result.appendSlice("%2C"),
            '/' => try result.appendSlice("%2F"),
            ':' => try result.appendSlice("%3A"),
            ';' => try result.appendSlice("%3B"),
            '=' => try result.appendSlice("%3D"),
            '?' => try result.appendSlice("%3F"),
            '@' => try result.appendSlice("%40"),
            else => try result.append(char),
        }
    }

    const web_path = result.toOwnedSlice();

    return Paths{
        .web_path = web_path,
        .html_path = html_path,
        .output_path = output_path,
    };
}

const SliceList = std.ArrayList([]const u8);

const lexicographicalCompare = struct {
    pub fn inner(innerCtx: void, a: []const u8, b: []const u8) bool {
        _ = innerCtx;

        var i: usize = 0;
        if (a.len == 0 or b.len == 0) return false;
        while (a[i] == b[i]) : (i += 1) {
            if (i == a.len or i == b.len) return false;
        }

        return a[i] < b[i];
    }
}.inner;

const TocContext = struct {
    current_relative_path: ?[]const u8 = null,
    ident: usize = 0,
};

/// Generate Table of Contents given the root folder.
///
/// Operates recursively.
pub fn generateToc(
    result: *StringList,
    pages: *const PageMap,
    folder: *const PageFolder,
    context: *TocContext,
) error{OutOfMemory}!void {
    var folder_iterator = folder.iterator();

    // step 1: find all the folders at this level.

    var folders = SliceList.init(result.allocator);
    defer folders.deinit();

    var files = SliceList.init(result.allocator);
    defer files.deinit();

    while (folder_iterator.next()) |entry| {
        switch (entry.value_ptr.*) {
            .dir => try folders.append(entry.key_ptr.*),
            .file => try files.append(entry.key_ptr.*),
        }
    }

    std.sort.sort([]const u8, folders.items, {}, lexicographicalCompare);
    std.sort.sort([]const u8, files.items, {}, lexicographicalCompare);

    // draw folders first (by recursing), then draw files second!
    if (context.ident > 0)
        try result.writer().print("<ul class=\"nested\">", .{});
    for (folders.items) |folder_name| {
        const child_folder_entry = folder.getEntry(folder_name).?;
        try result.writer().print("<li><span class=\"caret\">{s}</span>", .{folder_name});

        context.ident += 1;
        defer context.ident -= 1;

        try generateToc(result, pages, &child_folder_entry.value_ptr.*.dir, context);
    }
    for (files.items) |file_name| {
        const local_path = folder.get(file_name).?.file;

        var toc_output_path_buffer: [512]u8 = undefined;
        var toc_html_path_buffer: [2048]u8 = undefined;
        const toc_paths = try parsePaths(local_path, &toc_output_path_buffer, &toc_html_path_buffer);

        const title = std.fs.path.basename(toc_paths.output_path);

        try result.writer().print(
            "<li><a class=\"toc-link\" href=\"/{s}.html\">{s}</a></li>",
            .{ toc_paths.web_path, title },
        );
    }

    if (context.ident > 0)
        try result.writer().print("</ul>", .{});
}

pub fn main() anyerror!void {
    var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_instance.deinit();

    var alloc = allocator_instance.allocator();

    var args_it = std.process.args();
    _ = args_it.nextPosix();
    const build_file_path = args_it.nextPosix() orelse @panic("want build file path");
    const build_file_fd = try std.fs.cwd().openFile(build_file_path, .{ .read = true, .write = false });
    defer build_file_fd.close();

    var buffer: [8192]u8 = undefined;
    const build_file_data_count = try build_file_fd.read(&buffer);
    const build_file_data = buffer[0..build_file_data_count];

    var build_file = try BuildFile.parse(alloc, build_file_data);
    defer build_file.deinit();

    var vault_dir = try std.fs.cwd().openDir(build_file.vault_path, .{ .iterate = true });
    defer vault_dir.close();

    var pages = PageMap.init(alloc);
    defer pages.deinit();

    var titles = TitleMap.init(alloc);
    defer titles.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var string_arena = arena.allocator();

    var tree = PageTree.init(alloc);
    defer tree.deinit();

    for (build_file.includes.items) |include_path| {
        const joined_path = try std.fs.path.resolve(alloc, &[_][]const u8{ build_file.vault_path, include_path });
        defer alloc.free(joined_path);

        std.log.info("include path: {s}", .{joined_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openDir(joined_path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                const owned_path = try string_arena.dupe(u8, joined_path);
                try addFilePage(&pages, &titles, &tree, include_path, owned_path);
                continue;
            },

            else => return err,
        };
        defer included_dir.close();

        var walker = try included_dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .File => {
                    const joined_inner_path = try std.fs.path.join(string_arena, &[_][]const u8{ joined_path, entry.path });
                    const joined_local_inner_path = try std.fs.path.join(string_arena, &[_][]const u8{ include_path, entry.path });

                    // we own joined_inner_path's memory, so we can use it
                    try addFilePage(&pages, &titles, &tree, joined_local_inner_path, joined_inner_path);
                },

                else => {},
            }
        }
    }

    const resources = .{ .{ "resources/styles.css", "styles.css" }, .{ "resources/main.js", "main.js" } };

    inline for (resources) |resource| {
        const resource_text = @embedFile(resource.@"0");
        var resource_fd = try std.fs.cwd().createFile("public/" ++ resource.@"1", .{ .truncate = true });
        defer resource_fd.close();
        _ = try resource_fd.write(resource_text);
    }

    var pages_it = pages.iterator();

    var file_buffer: [16384]u8 = undefined;

    var toc_result = StringList.init(alloc);
    defer toc_result.deinit();

    try toc_result.writer().print("<ul id=\"tree-of-contents\">", .{});
    var toc_ctx: TocContext = .{};
    try generateToc(&toc_result, &pages, &tree.root.getPtr(".").?.dir, &toc_ctx);
    try toc_result.writer().print("</ul>", .{});

    const toc = toc_result.toOwnedSlice();
    defer alloc.free(toc);

    // first pass: use koino to parse all that markdown into html
    while (pages_it.next()) |entry| {
        const local_path = entry.key_ptr.*;
        const page = entry.value_ptr.*;
        const fspath = entry.value_ptr.*.filesystem_path;

        std.log.info("processing '{s}'", .{fspath});
        var page_fd = try std.fs.cwd().openFile(fspath, .{ .read = true, .write = false });
        defer page_fd.close();

        const read_bytes = try page_fd.read(&file_buffer);
        const file_contents = file_buffer[0..read_bytes];

        var p = try koino.parser.Parser.init(alloc, .{});
        defer p.deinit();
        try p.feed(file_contents);

        var doc = try p.finish();
        defer doc.deinit();

        var result = StringList.init(alloc);
        defer result.deinit();

        var output_path_buffer: [512]u8 = undefined;
        var html_path_buffer: [2048]u8 = undefined;
        const paths = try parsePaths(local_path, &output_path_buffer, &html_path_buffer);

        try result.writer().print(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\  <head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>{s}</title>
            \\    <script src="/main.js"></script>
            \\    <link rel="stylesheet" href="/styles.css">
            \\  </head>
            \\  <body>
            \\  <div class="toc">
        , .{page.title});

        try result.appendSlice(toc);

        try result.appendSlice(
            \\  </div>
            \\  <div class="text">
        );

        try result.writer().print(
            \\  <h2>{s}</h2><p>
        , .{page.title});

        try koino.html.print(result.writer(), alloc, .{}, doc);

        try result.appendSlice(
            \\  </p></div>
            \\  </body>
            \\</html>
        );

        const leading_path_to_file = std.fs.path.dirname(paths.output_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        var output_fd = try std.fs.cwd().createFile(paths.html_path, .{ .read = false, .truncate = true });
        defer output_fd.close();
        _ = try output_fd.write(result.items);

        entry.value_ptr.*.html_path = try string_arena.dupe(u8, paths.html_path);
        entry.value_ptr.*.web_path = try string_arena.dupe(u8, paths.web_path);
        entry.value_ptr.*.status = .Built;
    }
    const link_processor = LinkProcessor{
        .regex = try libpcre.Regex.compile("\\[\\[.+\\]\\]", .{}),
    };
    const check_processor = CheckmarkProcessor{
        .regex = try libpcre.Regex.compile("\\[.\\]", .{}),
    };

    const processors = .{ link_processor, check_processor };

    comptime var i = 0;
    inline while (i < processors.len) : (i += 1) {
        var processor = processors[i];
        defer processor.deinit();

        var link_pages_it = pages.iterator();
        while (link_pages_it.next()) |entry| {
            const page = entry.value_ptr.*;
            try std.testing.expectEqual(PageBuildStatus.Built, page.status);
            const html_path = entry.value_ptr.html_path.?;
            std.log.info("running {s} for file '{s}'", .{ @typeName(@TypeOf(processor)), html_path });

            var file_contents_mut: []const u8 = undefined;
            {
                var page_fd = try std.fs.cwd().openFile(html_path, .{ .read = true, .write = false });
                defer page_fd.close();
                const read_bytes = try page_fd.read(&file_buffer);
                file_contents_mut = file_buffer[0..read_bytes];
            }
            const file_contents = file_contents_mut;

            const matches = try processor.regex.captureAll(alloc, file_contents, .{});
            defer {
                for (matches.items) |match| alloc.free(match);
                matches.deinit();
            }

            var result = StringBuffer.init(alloc);
            defer result.deinit();

            // our replacing algorithm works by copying from 0 to match.start
            // then printing the wanted text
            // our replacing algorithm works by copying from match.end to another_match.start
            // then printing the wanted text
            // etc...
            // note: [[x]] will become <a href="/x">x</a>

            var last_match: ?libpcre.Capture = null;
            for (matches.items) |captures| {
                const match = captures[0].?;
                _ = if (last_match == null)
                    try result.writer().write(file_contents[0..match.start])
                else
                    try result.writer().write(file_contents[last_match.?.end..match.start]);

                var ctx = ProcessorContext{
                    .titles = &titles,
                    .pages = &pages,
                    .captures = captures,
                    .file_contents = file_contents,
                };

                try processor.handle(ctx, &result);
                last_match = match;
            }

            // last_match.?.end to end of file

            _ = if (last_match == null)
                try result.writer().write(file_contents[0..file_contents.len])
            else
                try result.writer().write(file_contents[last_match.?.end..file_contents.len]);

            {
                var page_fd = try std.fs.cwd().openFile(
                    entry.value_ptr.html_path.?,
                    .{ .read = false, .write = true },
                );
                defer page_fd.close();

                _ = try page_fd.write(result.items);
            }
        }
    }
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
