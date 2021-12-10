const std = @import("std");
const koino = @import("koino");

const BuildFile = @import("build_file.zig").BuildFile;

const PageBuildStatus = enum {
    Unbuilt,
    Built,
    Error,
};

const Page = struct {
    filesystem_path: []const u8,
    status: PageBuildStatus = .Unbuilt,
    raw_markdown: ?[]const u8 = null,
    errors: ?[]const u8 = null,
};
const PageMap = std.StringHashMap(Page);

fn addFilePage(
    pages: *PageMap,
    local_path: []const u8,
    fspath: []const u8,
) !void {
    std.log.info("new page: local='{s}' fs='{s}'", .{ local_path, fspath });
    try pages.put(local_path, Page{ .filesystem_path = fspath });
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
                try addFilePage(&pages, include_path, owned_path);
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
                    try addFilePage(&pages, joined_local_inner_path, joined_inner_path);
                },

                else => {},
            }
        }
    }

    var pages_it = pages.iterator();

    var file_buffer: [16384]u8 = undefined;

    while (pages_it.next()) |entry| {
        const local_path = entry.key_ptr.*;
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
        errdefer result.deinit();

        try koino.html.print(result.writer(), alloc, .{}, doc);

        var output_path_buffer: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator{ .buffer = &output_path_buffer, .end_index = 0 };
        var fixed_alloc = fba.allocator();
        // TODO have simple mem.join with slashes since its the web lmao
        const output_path = try std.fs.path.join(fixed_alloc, &[_][]const u8{ "public", local_path });

        var html_path_buffer: [2048]u8 = undefined;
        const offset = std.mem.replacementSize(u8, output_path, ".md", ".html");
        _ = std.mem.replace(u8, output_path, ".md", ".html", &html_path_buffer);
        const html_path = html_path_buffer[0..offset];

        const leading_path_to_file = std.fs.path.dirname(output_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        var output_fd = try std.fs.cwd().createFile(html_path, .{ .read = false, .truncate = true });
        defer output_fd.close();
        _ = try output_fd.write(result.items);
    }
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
