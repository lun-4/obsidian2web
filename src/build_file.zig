const std = @import("std");

const StringList = std.ArrayList([]const u8);

pub const ConfigDirectives = struct {
    strict_links: bool = true,
    index: ?[]const u8 = null,
    webroot: []const u8 = "",
    project_footer: bool = false,
    custom_css: ?[]const u8 = null,
};

fn parseBool(string: []const u8) bool {
    if (std.mem.eql(u8, "yes", string)) return true;
    if (std.mem.eql(u8, "no", string)) return false;
    return false;
}

pub const BuildFile = struct {
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    includes: StringList,
    config: ConfigDirectives,

    const Self = @This();

    pub fn parse(allocator: std.mem.Allocator, input_data: []const u8) !Self {
        var includes = StringList.init(allocator);
        errdefer includes.deinit();
        var file_lines_it = std.mem.split(u8, input_data, "\n");

        var config = ConfigDirectives{};

        var vault_path: ?[]const u8 = null;
        while (file_lines_it.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            const first_space_index =
                std.mem.indexOf(u8, line, " ") orelse return error.ParseError;

            const directive = std.mem.trim(u8, line[0..first_space_index], "\n");
            const value = line[first_space_index + 1 ..];
            if (std.mem.eql(u8, "vault", directive)) {
                vault_path = value;
            } else if (std.mem.eql(u8, "include", directive)) {
                try includes.append(value);
            } else if (std.mem.eql(u8, "index", directive)) {
                config.index = value;
            } else if (std.mem.eql(u8, "webroot", directive)) {
                config.webroot = value;
            } else if (std.mem.eql(u8, "strict_links", directive)) {
                config.strict_links = parseBool(value);
            } else if (std.mem.eql(u8, "project_footer", directive)) {
                config.project_footer = parseBool(value);
            } else if (std.mem.eql(u8, "custom_css", directive)) {
                config.custom_css = value;
            } else {
                std.log.err("unknown directive '{s}'", .{directive});
                return error.UnknownDirective;
            }
        }

        return Self{
            .allocator = allocator,
            .vault_path = vault_path orelse return error.VaultPathRequired,
            .includes = includes,
            .config = config,
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
        \\index Abcdef
    ;

    var build_file = try BuildFile.parse(std.testing.allocator, test_file);
    defer build_file.deinit();
    try std.testing.expectEqualStrings("/home/test/vault", build_file.vault_path);
    try std.testing.expectEqualStrings("Abcdef", build_file.config.index orelse return error.UnexpectedNull);
    try std.testing.expectEqual(@as(usize, 4), build_file.includes.items.len);
}
