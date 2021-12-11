const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

const BuildFile = @import("build_file.zig").BuildFile;

const PageBuildStatus = enum {
    Unbuilt,
    Built,
    Resolved,
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

fn addFilePage(
    pages: *PageMap,
    titles: *TitleMap,
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

    for (build_file.includes.items) |include_path| {
        const joined_path = try std.fs.path.join(alloc, &[_][]const u8{ build_file.vault_path, include_path });
        defer alloc.free(joined_path);
        std.log.info("include path: {s}", .{joined_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openDir(joined_path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                const owned_path = try string_arena.dupe(u8, joined_path);
                try addFilePage(&pages, &titles, include_path, owned_path);
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
                    try addFilePage(&pages, &titles, joined_local_inner_path, joined_inner_path);
                },

                else => {},
            }
        }
    }

    {
        var styles_css_fd = try std.fs.cwd().createFile("public/styles.css", .{ .truncate = true });
        defer styles_css_fd.close();
        const styles_text = @embedFile("resources/styles.css");
        _ = try styles_css_fd.write(styles_text);
    }

    var pages_it = pages.iterator();

    var file_buffer: [16384]u8 = undefined;

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

        var result = std.ArrayList(u8).init(alloc);
        defer result.deinit();

        try result.writer().print(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\  <head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>{s}</title>
            \\    <link rel="stylesheet" href="styles.css">
            \\  </head>
            \\  <body class="theme-dark">
        , .{page.title});

        try koino.html.print(result.writer(), alloc, .{}, doc);

        try result.appendSlice(
            \\  </body>
            \\</html>
        );

        var output_path_buffer: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator{ .buffer = &output_path_buffer, .end_index = 0 };
        var fixed_alloc = fba.allocator();
        // TODO have simple mem.join with slashes since its the web lmao
        const output_path = try std.fs.path.join(fixed_alloc, &[_][]const u8{ "public", local_path });
        const web_path = local_path[0 .. local_path.len - 3];

        var html_path_buffer: [2048]u8 = undefined;
        const offset = std.mem.replacementSize(u8, output_path, ".md", ".html");
        _ = std.mem.replace(u8, output_path, ".md", ".html", &html_path_buffer);
        const html_path = html_path_buffer[0..offset];

        const leading_path_to_file = std.fs.path.dirname(output_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        var output_fd = try std.fs.cwd().createFile(html_path, .{ .read = false, .truncate = true });
        defer output_fd.close();
        _ = try output_fd.write(result.items);

        entry.value_ptr.*.html_path = try string_arena.dupe(u8, html_path);
        entry.value_ptr.*.web_path = try string_arena.dupe(u8, web_path);
        entry.value_ptr.*.status = .Built;
    }
    var link_pages_it = pages.iterator();

    // second pass, resolve all the links!
    const regex = try libpcre.Regex.compile("\\[\\[.+\\]\\]", .{});
    defer regex.deinit();
    while (link_pages_it.next()) |entry| {
        try std.testing.expectEqual(PageBuildStatus.Built, entry.value_ptr.*.status);
        const html_path = entry.value_ptr.html_path.?;

        std.log.info("processing links for file '{s}'", .{html_path});

        var file_contents_mut: []const u8 = undefined;
        {
            var page_fd = try std.fs.cwd().openFile(html_path, .{ .read = true, .write = false });
            defer page_fd.close();

            const read_bytes = try page_fd.read(&file_buffer);
            file_contents_mut = file_buffer[0..read_bytes];
        }
        const file_contents = file_contents_mut;

        const matches = try regex.captureAll(alloc, file_contents, .{});
        defer {
            for (matches.items) |match| alloc.free(match);
            matches.deinit();
        }

        var result = std.ArrayList(u8).init(alloc);
        defer result.deinit();

        var last_match: ?libpcre.Capture = null;

        // our replacing algorithm works by copying from 0 to match.start
        // then printing the <a> tag
        // our replacing algorithm works by copying from match.end to another_match.start
        // then printing the <a> tag
        // etc...
        // note: [[x]] will become <a href="/x">x</a>

        for (matches.items) |captures| {
            const match = captures[0].?;
            const referenced_title = file_contents[match.start + 2 .. match.end - 2];
            std.log.info("link to '{s}'", .{referenced_title});

            // TODO strict_links support here
            var page_local_path = titles.get(referenced_title).?;
            var page = pages.get(page_local_path).?;

            _ = if (last_match == null)
                try result.writer().write(file_contents[0..match.start])
            else
                try result.writer().write(file_contents[last_match.?.end..match.start]);
            try result.writer().print("<a href=\"{s}.html\">{s}</a>", .{ page.web_path, referenced_title });
            last_match = match;
        }

        // last_match.?.end to end of file

        _ = if (last_match == null)
            try result.writer().write(file_contents[0..file_contents.len])
        else
            try result.writer().write(file_contents[last_match.?.end..file_contents.len]);

        {
            var page_fd = try std.fs.cwd().openFile(entry.value_ptr.html_path.?, .{ .read = false, .write = true });
            defer page_fd.close();

            _ = try page_fd.write(result.items);

            entry.value_ptr.*.status = .Resolved;
        }
    }
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
