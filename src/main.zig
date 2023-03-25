const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

pub const OwnedStringList = std.ArrayList([]const u8);
pub const BuildFile = @import("build_file.zig").BuildFile;
const processors = @import("processors.zig");
const util = @import("util.zig");

pub const std_options = struct {
    pub const log_level = .debug;
};

const logger = std.log.scoped(.obsidian2web);

const Page = @import("Page.zig");
const PageMap = std.StringHashMap(Page);

// article on path a/b/c/d/e.md is mapped as "e" in this title map.
const TitleMap = std.StringHashMap([]const u8);

const PathTree = @import("./PathTree.zig");
pub const StringBuffer = std.ArrayList(u8);
pub const SliceList = std.ArrayList([]const u8);

const TreeGeneratorContext = struct {
    current_folder: ?PathTree.PageFolder = null,
    root_folder: ?PathTree.PageFolder = null,
    indentation_level: usize = 0,
};

fn printHashMap(map: anytype) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        logger.debug(
            "key={s} value={any}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
    }
}

fn writePageTree(
    writer: anytype,
    ctx: *const Context,
    tree_context: TreeGeneratorContext,
    /// Set this if generating a tree in a specific page.
    ///
    /// Set to null if on index page.
    generating_tree_for: ?*const Page,
) !void {
    const root_folder =
        tree_context.root_folder orelse
        PathTree.walkToDir(ctx.tree.root, ctx.build_file.vault_path);
    const current_folder =
        tree_context.current_folder orelse root_folder;

    // step 1: find all the folders at this level.

    var folders = SliceList.init(ctx.allocator);
    defer folders.deinit();

    var files = SliceList.init(ctx.allocator);
    defer files.deinit();

    {
        var folder_iterator = current_folder.iterator();

        while (folder_iterator.next()) |entry| {
            switch (entry.value_ptr.*) {
                .dir => try folders.append(entry.key_ptr.*),
                .file => try files.append(entry.key_ptr.*),
            }
        }

        std.sort.sort([]const u8, folders.items, {}, util.lexicographicalCompare);
        std.sort.sort([]const u8, files.items, {}, util.lexicographicalCompare);
    }

    // draw folders first (they recurse)
    // then draw files second

    for (folders.items) |folder_name| {
        try writer.print("<details>", .{});

        const child_folder = current_folder.getPtr(folder_name).?.dir;
        try writer.print(
            "<summary>{s}</summary>\n",
            .{util.unsafeHTML(folder_name)},
        );

        var child_context = TreeGeneratorContext{
            .indentation_level = tree_context.indentation_level + 1,
            .current_folder = child_folder,
        };

        try writePageTree(writer, ctx, child_context, generating_tree_for);
        try writer.print("</details>\n", .{});
    }

    const for_web_path = if (generating_tree_for) |current_page|
        try current_page.fetchWebPath(ctx.allocator)
    else
        null;
    defer if (for_web_path) |path| ctx.allocator.free(path);

    try writer.print("<ul>\n", .{});
    for (files.items) |file_name| {
        const file_path = current_folder.get(file_name).?.file;
        const page = ctx.pages.get(file_path).?;

        const page_web_path = try page.fetchWebPath(ctx.allocator);
        defer ctx.allocator.free(page_web_path);

        const current_attr = if (for_web_path != null and std.mem.eql(u8, for_web_path.?, page_web_path))
            "aria-current=\"page\" "
        else
            " ";

        try writer.print(
            "<li><a class=\"toc-link\" {s}href=\"{s}\">{s}</a></li>\n",
            .{
                current_attr,
                ctx.webPath("/{s}", .{page_web_path}),
                util.unsafeHTML(page.title),
            },
        );
    }
    try writer.print("</ul>\n", .{});
}

const testing = @import("testing.zig");
test "page tree sets aria-current" {
    const TEST_DATA = .{
        .{ "awoogapage", "", "<a class=\"toc-link\" aria-current=\"page\" href=\"/awoogapage.html\">awoogapage</a>" },
    };

    inline for (TEST_DATA) |test_entry| {
        const title = test_entry.@"0";
        const input = test_entry.@"1";
        const expected_output = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, title, input, expected_output);
    }
}

const FOOTER =
    \\  <footer>
    \\    made with love using <a href="https://github.com/lun-4/obsidian2web">obsidian2web!</a>
    \\  </footer>
;

pub const ArenaHolder = struct {
    paths: std.heap.ArenaAllocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .paths = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.paths.deinit();
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    build_file: BuildFile,
    vault_dir: std.fs.IterableDir,
    arenas: ArenaHolder,
    pages: PageMap,
    titles: TitleMap,
    tree: PathTree,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        build_file: BuildFile,
        vault_dir: std.fs.IterableDir,
    ) Self {
        return Self{
            .allocator = allocator,
            .build_file = build_file,
            .vault_dir = vault_dir,
            .arenas = ArenaHolder.init(allocator),
            .pages = PageMap.init(allocator),
            .titles = TitleMap.init(allocator),
            .tree = PathTree.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arenas.deinit();
        {
            var it = self.pages.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit();
        }
        self.pages.deinit();
        self.titles.deinit();
        self.tree.deinit();
    }

    pub fn pathAllocator(self: *Self) std.mem.Allocator {
        return self.arenas.paths.allocator();
    }

    pub fn addPage(self: *Self, path: []const u8) !void {
        if (!std.mem.endsWith(u8, path, ".md")) return;

        const owned_fspath = try self.pathAllocator().dupe(u8, path);
        var pages_result = try self.pages.getOrPut(owned_fspath);
        if (!pages_result.found_existing) {
            var page = try Page.fromPath(self, owned_fspath);
            pages_result.value_ptr.* = page;
            try self.titles.put(page.title, page.filesystem_path);
            try self.tree.addPath(page.filesystem_path);
        }
    }

    pub fn pageFromPath(self: Self, path: []const u8) ?Page {
        return self.pages.get(path);
    }

    pub fn pageFromTitle(self: Self, title: []const u8) ?Page {
        return self.pages.get(self.titles.get(title) orelse return null);
    }

    pub fn webPath(
        self: Self,
        comptime fmt: []const u8,
        args: anytype,
    ) util.WebPathPrinter(@TypeOf(args), fmt) {
        comptime std.debug.assert(fmt[0] == '/'); // must be path
        return util.WebPathPrinter(@TypeOf(args), fmt){
            .ctx = self,
            .args = args,
        };
    }
};

pub const ByteList = std.ArrayList(u8);

// insert into PageTree from the given include paths
pub fn iterateVaultPath(ctx: *Context) !void {
    for (ctx.build_file.includes.items) |relative_include_path| {
        const absolute_include_path = try std.fs.path.resolve(
            ctx.allocator,
            &[_][]const u8{ ctx.build_file.vault_path, relative_include_path },
        );
        defer ctx.allocator.free(absolute_include_path);

        logger.info("including given path: '{s}'", .{absolute_include_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openIterableDir(
            absolute_include_path,
            .{},
        ) catch |err| switch (err) {
            error.NotDir => {
                try ctx.addPage(absolute_include_path);
                continue;
            },

            else => return err,
        };
        defer included_dir.close();

        // Walker already recurses into all child paths

        var walker = try included_dir.walk(ctx.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .File => {
                    const absolute_file_path = try std.fs.path.join(
                        ctx.allocator,
                        &[_][]const u8{ absolute_include_path, entry.path },
                    );
                    defer ctx.allocator.free(absolute_file_path);
                    try ctx.addPage(absolute_file_path);
                },

                else => {},
            }
        }
    }
}

pub fn main() anyerror!void {
    var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_instance.deinit();

    var allocator = allocator_instance.allocator();

    var args_it = std.process.args();
    defer args_it.deinit();

    _ = args_it.skip();
    const build_file_path = args_it.next() orelse {
        logger.err("pass path to build file as 1st argument", .{});
        return error.InvalidArguments;
    };

    var build_file_data_buffer: [8192]u8 = undefined;
    const build_file_data = blk: {
        const build_file_fd = try std.fs.cwd().openFile(
            build_file_path,
            .{ .mode = .read_only },
        );
        defer build_file_fd.close();

        const build_file_data_count = try build_file_fd.read(
            &build_file_data_buffer,
        );
        break :blk build_file_data_buffer[0..build_file_data_count];
    };

    var build_file = try BuildFile.parse(allocator, build_file_data);
    defer build_file.deinit();

    var vault_dir = try std.fs.cwd().openIterableDir(build_file.vault_path, .{});
    defer vault_dir.close();

    var ctx = Context.init(allocator, build_file, vault_dir);
    defer ctx.deinit();

    // main pipeline starts here
    {
        try iterateVaultPath(&ctx);
        try std.fs.cwd().makePath("public/");
        try createStaticResources(ctx);

        // for each page
        //  - pass 1: run pre processors
        //  - pass 2: turn page markdown into html (koino)
        //  - pass 3: run post processors

        var pre_processors = try initProcessors(PreProcessors);
        defer deinitProcessors(pre_processors);

        var post_processors = try initProcessors(PostProcessors);
        defer deinitProcessors(post_processors);

        var pages_it = ctx.pages.iterator();
        while (pages_it.next()) |entry| {
            try runProcessors(&ctx, &pre_processors, entry.value_ptr, .{ .pre = true });
            try mainPass(&ctx, entry.value_ptr);
            try runProcessors(&ctx, &post_processors, entry.value_ptr, .{});
        }
    }

    // generate index page
    try generateIndexPage(ctx);
    try generateTagPages(ctx);
}

pub const PostProcessors = struct {
    checkmark: processors.CheckmarkProcessor,
    cross_page_link: processors.CrossPageLinkProcessor,
};

pub const PreProcessors = struct {
    tag: processors.TagProcessor,
    page_toc: processors.TableOfContentsProcessor,
};

pub fn initProcessors(comptime ProcessorHolderT: type) !ProcessorHolderT {
    var proc: ProcessorHolderT = undefined;
    inline for (@typeInfo(ProcessorHolderT).Struct.fields) |field| {
        @field(proc, field.name) = try field.type.init();
    }
    return proc;
}

pub fn deinitProcessors(procs: anytype) void {
    inline for (@typeInfo(@TypeOf(procs)).Struct.fields) |field| {
        field.type.deinit(@field(procs, field.name));
    }
}

// Contains data that will be sent to the processor
pub fn Holder(comptime ProcessorT: type, comptime WriterT: type) type {
    return struct {
        ctx: *Context,
        processor: ProcessorT,
        page: *Page,
        last_capture: *?libpcre.Capture,
        out: WriterT,
    };
}

const RunProcessorOptions = struct {
    pre: bool = false,
};

pub fn runProcessors(
    ctx: *Context,
    processor_list: anytype,
    page: *Page,
    options: RunProcessorOptions,
) !void {
    logger.info("running processors processing {} {}", .{ page, options });

    var temp_output_path: []const u8 = if (options.pre) blk: {
        std.debug.assert(page.state == .unbuilt);
        var markdown_output_path = "/tmp/sex.md"; // TODO fetchTemporaryMarkdownPath();

        try std.fs.Dir.copyFile(
            std.fs.cwd(),
            page.filesystem_path,
            std.fs.cwd(),
            markdown_output_path,
            .{},
        );
        break :blk markdown_output_path[0..];
    } else blk: {
        std.debug.assert(page.state == .main);
        break :blk try page.fetchHtmlPath(ctx.allocator);
    };

    defer page.state = if (options.pre)
        .{ .pre = temp_output_path }
    else
        .{ .post = {} };

    defer if (!options.pre) ctx.allocator.free(temp_output_path);

    inline for (
        @typeInfo(@typeInfo(@TypeOf(processor_list)).Pointer.child).Struct.fields,
    ) |field| {
        var processor = @field(processor_list, field.name);
        logger.debug("running {s}", .{@typeName(field.type)});

        const output_file_contents = blk: {
            var output_fd = try std.fs.cwd().openFile(
                temp_output_path,
                .{ .mode = .read_only },
            );
            defer output_fd.close();

            break :blk try output_fd.reader().readAllAlloc(
                ctx.allocator,
                std.math.maxInt(usize),
            );
        };
        defer ctx.allocator.free(output_file_contents);

        var result = ByteList.init(ctx.allocator);
        defer result.deinit();

        const HolderT = Holder(@TypeOf(processor), ByteList.Writer);

        var last_capture: ?libpcre.Capture = null;
        var context_holder = HolderT{
            .ctx = ctx,
            .processor = processor,
            .page = page,
            .last_capture = &last_capture,
            .out = result.writer(),
        };

        try util.captureWithCallback(
            processor.regex,
            output_file_contents,
            .{},
            ctx.allocator,
            HolderT,
            &context_holder,
            struct {
                fn inner(
                    holder: *HolderT,
                    full_string: []const u8,
                    capture: []?libpcre.Capture,
                ) !void {
                    const first_group = capture[0].?;
                    _ = if (holder.last_capture.* == null)
                        try holder.out.write(
                            full_string[0..first_group.start],
                        )
                    else
                        try holder.out.write(
                            full_string[holder.last_capture.*.?.end..first_group.start],
                        );

                    try holder.processor.handle(
                        holder,
                        full_string,
                        capture,
                    );
                    holder.last_capture.* = first_group;
                }
            }.inner,
        );

        _ = if (last_capture == null)
            try result.writer().write(
                output_file_contents[0..output_file_contents.len],
            )
        else
            try result.writer().write(
                output_file_contents[last_capture.?.end..output_file_contents.len],
            );

        {
            var output_fd = try std.fs.cwd().openFile(
                temp_output_path,
                .{ .mode = .write_only },
            );
            defer output_fd.close();
            _ = try output_fd.write(result.items);
        }
    }
}

pub fn mainPass(ctx: *Context, page: *Page) !void {
    logger.info("processing '{s}'", .{page.filesystem_path});

    // TODO find a way to feed chunks of file to koino
    //
    // i did that before and failed miserably...
    const input_page_contents = blk: {
        var page_fd = try std.fs.cwd().openFile(
            page.state.pre,
            .{ .mode = .read_only },
        );
        defer page_fd.close();

        break :blk try page_fd.reader().readAllAlloc(
            ctx.allocator,
            std.math.maxInt(usize),
        );
    };
    defer ctx.allocator.free(input_page_contents);

    const options = .{
        .extensions = .{
            .autolink = true,
            .strikethrough = true,
            .table = true,
        },
        .render = .{ .hard_breaks = true, .unsafe = true },
    };

    var parser = try koino.parser.Parser.init(ctx.allocator, options);
    defer parser.deinit();

    try parser.feed(input_page_contents);

    var doc = try parser.finish();
    defer doc.deinit();

    var output_fd = blk: {
        var html_path = try page.fetchHtmlPath(ctx.allocator);
        defer ctx.allocator.free(html_path);
        logger.info("writing to '{s}'", .{html_path});

        const leading_path_to_file = std.fs.path.dirname(html_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        break :blk try std.fs.cwd().createFile(
            html_path,
            .{ .read = false, .truncate = true },
        );
    };
    defer output_fd.close();

    defer page.state = .{ .main = {} };

    var output = output_fd.writer();

    // write time
    {
        try writeHead(output, ctx.build_file, page.title);

        try writePageTree(output, ctx, .{}, page);
        //try output.print(
        //    \\  </nav>
        //    \\  <nav class="page-toc">
        //, .{});
        if (page.titles) |titles| for (titles.items) |title| {
            try output.print(
                \\  <a href="#{s}">{s}</a></p>
            , .{
                util.WebTitlePrinter{ .title = title },
                title,
            });
        };

        try output.print(
            \\  </nav>
            \\  <main class="text">
        , .{});
        try output.print(
            \\    <h2>{s}</h2><p>
        , .{util.unsafeHTML(page.title)});
        try koino.html.print(output, ctx.allocator, options, doc);

        try output.print(
            \\  </p></main>
            \\ {s}
            \\ </body>
            \\ </html>
        , .{if (ctx.build_file.config.project_footer) FOOTER else ""});
    }
}

fn generateIndexPage(ctx: Context) !void {
    // if an index file was provided in the config, copypaste the resulting
    // HTML as that'll work
    if (ctx.build_file.config.index) |relative_index_path| {
        const page_path = try std.fs.path.resolve(
            ctx.allocator,
            &[_][]const u8{ ctx.build_file.vault_path, relative_index_path },
        );
        defer ctx.allocator.free(page_path);
        const page =
            ctx.pages.get(page_path) orelse return error.IndexPageNotFound;

        const html_path = try page.fetchHtmlPath(ctx.allocator);
        defer ctx.allocator.free(html_path);

        try std.fs.Dir.copyFile(
            std.fs.cwd(),
            html_path,
            std.fs.cwd(),
            "public/index.html",
            .{},
        );
    } else {
        // if not, generate our own empty file
        // that contains just the table of contents

        const index_out_fd = try std.fs.cwd().createFile(
            "public/index.html",
            .{ .truncate = true },
        );
        defer index_out_fd.close();

        const writer = index_out_fd.writer();

        try writeHead(writer, ctx.build_file, "Index Page");
        try writePageTree(writer, &ctx, .{}, null);
        try writeEmptyPage(writer, ctx.build_file);
    }
}

const PageList = std.ArrayList(*const Page);

fn generateTagPages(ctx: Context) !void {
    var tag_map = std.StringHashMap(PageList).init(ctx.allocator);

    defer {
        var tags_it = tag_map.iterator();
        while (tags_it.next()) |entry| entry.value_ptr.deinit();
        tag_map.deinit();
    }

    var it = ctx.pages.iterator();
    while (it.next()) |entry| {
        var page = entry.value_ptr;
        logger.debug("processing tags in {}", .{page});

        if (page.tags) |tags| for (tags.items) |tag| {
            var maybe_pagelist = try tag_map.getOrPut(tag);

            if (maybe_pagelist.found_existing) {
                try maybe_pagelist.value_ptr.append(entry.value_ptr);
            } else {
                maybe_pagelist.value_ptr.* = PageList.init(ctx.allocator);
                try maybe_pagelist.value_ptr.append(entry.value_ptr);
            }
        };
    }

    try std.fs.cwd().makePath("public/_/tags");

    var tags_it = tag_map.iterator();
    while (tags_it.next()) |entry| {
        var tag_name = entry.key_ptr.*;
        logger.info("generating tag page: {s}", .{tag_name});
        var buf: [512]u8 = undefined;
        const output_path = try std.fmt.bufPrint(
            &buf,
            "public/_/tags/{s}.html",
            .{tag_name},
        );

        var output_file = try std.fs.cwd().createFile(
            output_path,
            .{ .read = false, .truncate = true },
        );
        defer output_file.close();

        var writer = output_file.writer();

        try writeHead(writer, ctx.build_file, tag_name);
        _ = try writer.write(
            \\  </nav>
            \\  <main class="text">
        );

        std.sort.sort(*const Page, entry.value_ptr.items, {}, struct {
            fn inner(context: void, a: *const Page, b: *const Page) bool {
                _ = context;
                return a.ctime < b.ctime;
            }
        }.inner);

        try writer.print("<h1>{s}</h1><p>", .{util.unsafeHTML(tag_name)});
        try writer.print("({d} pages)", .{entry.value_ptr.items.len});
        try writer.print("<div class=\"tag-page\">", .{});

        for (entry.value_ptr.items) |page| {
            var page_fd = try std.fs.cwd().openFile(
                page.filesystem_path,
                .{ .mode = .read_only },
            );
            defer page_fd.close();
            var preview_buffer: [256]u8 = undefined;
            const page_preview_text_read_bytes = try page_fd.read(&preview_buffer);
            const page_preview_text = preview_buffer[0..page_preview_text_read_bytes];
            const page_web_path = try page.fetchWebPath(ctx.allocator);
            defer ctx.allocator.free(page_web_path);
            try writer.print(
                \\ <div class="page-preview">
                \\ 	<a href="{s}">
                \\ 		<div class="page-preview-title"><h2>{s}</h2></div>
                \\ 		<div class="page-preview-text">{s}&hellip;</div>
                \\ 	</a>
                \\ </div><p>
            ,
                .{
                    ctx.webPath("/{s}", .{page_web_path}),
                    util.unsafeHTML(page.title),
                    util.unsafeHTML(page_preview_text),
                },
            );
        }

        try writer.print("</div>", .{});

        _ = try writer.write(
            \\  </main>
        );

        if (ctx.build_file.config.project_footer) {
            _ = try writer.write(FOOTER);
        }

        _ = try writer.write(
            \\  </body>
            \\</html>
        );
    }
}

fn writeHead(writer: anytype, build_file: BuildFile, title: []const u8) !void {
    try writer.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>{s}</title>
        \\    <script src="{s}/main.js"></script>
        \\    <link rel="stylesheet" href="{s}/styles.css">
        \\  </head>
        \\  <body>
        \\  <nav class="toc">
    , .{ util.unsafeHTML(title), build_file.config.webroot, build_file.config.webroot });
}

// TODO make this usable on the main pipeline too?
fn writeEmptyPage(writer: anytype, build_file: BuildFile) !void {
    _ = try writer.write(
        \\  </nav>
        \\  <main class="text">
        \\  </main>
    );

    if (build_file.config.project_footer) {
        _ = try writer.write(FOOTER);
    }

    _ = try writer.write(
        \\  </body>
        \\</html>
    );
}

fn createStaticResources(ctx: Context) !void {
    const RESOURCES = .{
        .{ "resources/styles.css", "styles.css" },
        .{ "resources/main.js", "main.js" },
    };

    inline for (RESOURCES) |resource| {
        const resource_text = @embedFile(resource.@"0");
        const resource_filename = resource.@"1";
        const output_fspath = "public/" ++ resource_filename;

        if (std.mem.eql(u8, resource_filename, "styles.css") and
            ctx.build_file.config.custom_css != null)
        {
            try std.fs.Dir.copyFile(
                std.fs.cwd(),
                ctx.build_file.config.custom_css.?,
                std.fs.cwd(),
                output_fspath,
                .{},
            );
        } else {
            var output_fd = try std.fs.cwd().createFile(
                output_fspath,
                .{ .truncate = true },
            );
            defer output_fd.close();
            // write it all lmao
            const written_bytes = try output_fd.write(resource_text);
            std.debug.assert(written_bytes == resource_text.len);
        }
    }
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
