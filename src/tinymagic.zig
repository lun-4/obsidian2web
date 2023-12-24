const std = @import("std");

const FileType = enum {
    image,
    video,
};

const EXTENSIONS = .{
    .{ .image, .{ "jpg", "png", "webp", "jpeg", "jxl", "gif" } },
    .{ .video, .{ "mp4", "webm", "mkv" } },
};

pub fn fileTypeFromPath(fspath: []const u8) !FileType {
    const extension = std.fs.path.extension(fspath)[1..];

    inline for (EXTENSIONS) |extension_decl| {
        const possible_file_type = @as(FileType, extension_decl.@"0");
        inline for (extension_decl.@"1") |valid_extension| {
            if (std.mem.eql(u8, extension, valid_extension)) {
                return possible_file_type;
            }
        }
    }
    return error.InvalidExtension;
}
