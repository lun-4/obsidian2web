const std = @import("std");

const BuildFile = @import("build_file.zig").BuildFile;

pub fn main() anyerror!void {
    var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = allocator_instance.deinit();
    }
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
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
