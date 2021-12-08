const std = @import("std");

const StringList = std.ArrayList([]const u8);

pub const BuildFile = struct {
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    includes: StringList,

    const Self = @This();

    pub fn parse(allocator: std.mem.Allocator, input_data: []const u8) !Self {
        var includes = StringList.init(allocator);
        var file_lines_it = std.mem.split(u8, input_data, "\n");

        var vault_path: ?[]const u8 = null;
        while (file_lines_it.next()) |line| {
            if (line.len == 0) continue;
            const first_space_index = std.mem.indexOf(u8, line, " ") orelse return error.ParseError;

            const directive = std.mem.trim(u8, line[0..first_space_index], "\n");
            const value = line[first_space_index + 1 ..];
            if (std.mem.eql(u8, "vault", directive)) vault_path = value;
            if (std.mem.eql(u8, "include", directive)) try includes.append(value);
        }

        return Self{
            .allocator = allocator,
            .vault_path = vault_path.?,
            .includes = includes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.includes.deinit();
    }
};

test "build file works" {
    const test_file =
        \\vault /home/test/vault
        \\include Folder1/
        \\include ./
        \\include Folder2/
        \\include TestFile.md
    ;

    var build_file = try BuildFile.parse(std.testing.allocator, test_file);
    defer build_file.deinit();
    try std.testing.expectEqualStrings("/home/test/vault", build_file.vault_path);
    try std.testing.expectEqual(@as(usize, 4), build_file.includes.items.len);
}
