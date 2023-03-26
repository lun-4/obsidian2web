const std = @import("std");
const root = @import("main.zig");
var tmp_dir_realpath_buffer: [std.os.PATH_MAX]u8 = undefined;
const logger = std.log.scoped(.obsidian2web_testing);
pub const TestContext = struct {
    ctx: root.Context,
    tmp_dir: std.testing.TmpIterableDir,
    build_file: root.BuildFile,

    const Self = @This();
    const allocator = std.testing.allocator;

    pub fn init() TestContext {
        var tmp_dir = std.testing.tmpIterableDir(.{});

        const tmp_dir_realpath = tmp_dir.iterable_dir.dir.realpath(
            ".",
            &tmp_dir_realpath_buffer,
        ) catch unreachable;

        var build_file = root.BuildFile{
            .allocator = allocator,
            .vault_path = tmp_dir_realpath,
            .includes = root.SliceList.init(allocator),
            .config = .{},
        };

        build_file.includes.append(".") catch unreachable;

        var ctx = root.Context.init(allocator, build_file, tmp_dir.iterable_dir);

        return TestContext{
            .ctx = ctx,
            .tmp_dir = tmp_dir,
            .build_file = build_file,
        };
    }

    pub fn createPage(self: *Self, comptime title: []const u8, data: []const u8) !void {
        var file = try self.tmp_dir.iterable_dir.dir.createFile(title ++ ".md", .{});
        defer file.close();
        _ = try file.write(data);
    }

    pub fn deinit(self: *Self) void {
        self.build_file.deinit();
        self.ctx.deinit();
        //self.tmp_dir.cleanup();
    }

    pub fn run(self: *Self) !void {
        try root.iterateVaultPath(&self.ctx);
        try std.fs.cwd().makePath("public/");

        var pre_processors = try root.initProcessors(root.PreProcessors);
        defer root.deinitProcessors(pre_processors);

        var post_processors = try root.initProcessors(root.PostProcessors);
        defer root.deinitProcessors(post_processors);

        var pages_it = self.ctx.pages.iterator();
        while (pages_it.next()) |entry| {
            try root.runProcessors(&self.ctx, &pre_processors, entry.value_ptr, .{ .pre = true });
            try root.mainPass(&self.ctx, entry.value_ptr);
            try root.runProcessors(&self.ctx, &post_processors, entry.value_ptr, .{});
        }
    }
};

pub fn runTestWithSingleEntry(
    test_ctx: *TestContext,
    comptime title: []const u8,
    input: []const u8,
    expected_output: []const u8,
) !void {
    const allocator = std.testing.allocator;
    try test_ctx.createPage(title, input);
    try test_ctx.run();

    //var page = try test_ctx.fetchOnlySinglePage();
    var pages_it = test_ctx.ctx.pages.iterator();
    var page = pages_it.next().?.value_ptr;

    const htmlpath = try page.fetchHtmlPath(std.testing.allocator);
    defer std.testing.allocator.free(htmlpath);

    var output_file = try std.fs.cwd().openFile(htmlpath, .{});
    defer output_file.close();
    var output_text = try output_file.reader().readAllAlloc(std.testing.allocator, 1024 * 1024);
    defer allocator.free(output_text);

    const maybe_found = std.mem.indexOf(u8, output_text, expected_output);
    if (maybe_found == null) {
        logger.err(
            "text '{s}' not found in '{s}'",
            .{ expected_output, htmlpath },
        );
    }
    try std.testing.expect(maybe_found != null);
}

pub fn runTestWithDataset(test_data: anytype) !void {
    inline for (test_data) |test_entry| {
        comptime std.debug.assert(test_entry.len == 2);
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";

        var test_ctx = TestContext.init();
        defer test_ctx.deinit();

        try runTestWithSingleEntry(&test_ctx, "test", input, expected_output);
    }
}
