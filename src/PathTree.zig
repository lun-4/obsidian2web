const std = @import("std");
const main = @import("root");
const util = @import("util.zig");
const Context = main.Context;
const OwnedStringList = main.OwnedStringList;
const logger = std.log.scoped(.obsidian2web_page);

allocator: std.mem.Allocator,
root: PageFolder,

pub const PageFile = union(enum) {
    dir: PageFolder,
    file: []const u8,
};

pub const PageFolder = std.StringHashMap(PageFile);

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .allocator = allocator,
        .root = PageFolder.init(allocator),
    };
}

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

pub fn deinit(self: *Self) void {
    deinitPageFolder(&self.root);
}

/// Recursively walk from a PageFolder to another PageFolder, using `to` as
/// a guide.
pub fn walkToDir(from: PageFolder, to: []const u8) PageFolder {
    var it = std.mem.split(u8, to, std.fs.path.sep_str);
    const component = it.next().?;
    _ = it.next() orelse return from;
    return walkToDir(from.get(component).?.dir, to[component.len + 1 ..]);
}

pub fn addPath(self: *Self, fspath: []const u8) !void {
    const total_seps = std.mem.count(u8, fspath, std.fs.path.sep_str);
    var path_it = std.mem.split(u8, fspath, std.fs.path.sep_str);

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
                current_page = &current_page.?.getPtr(path_component).?.dir;
            }
        }
    }
}
