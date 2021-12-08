const std = @import("std");

const BuildFile = @import("build_file.zig").BuildFile;

const PageMap = std.StringHashMap(usize);

fn addFilePage(pages: *PageMap, path: []const u8) !void {
    try pages.put(path, 1);
    try std.testing.expectEqual(@as(?usize, 1), pages.get(path));
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
                std.log.info("file path from include: {s}", .{joined_path});
                const owned_path = try string_arena.dupe(u8, joined_path);
                try addFilePage(&pages, owned_path);
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
                    // we do not own the memory given by entry.name, so dupe it
                    // into our string arena

                    const owned_path = try string_arena.dupe(u8, entry.path);
                    std.log.info("file path: {s}", .{owned_path});
                    try addFilePage(&pages, owned_path);
                },

                else => {},
            }
        }
    }
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
