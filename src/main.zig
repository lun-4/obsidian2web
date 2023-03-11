const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

const StringList = std.ArrayList(u8);
pub const OwnedStringList = std.ArrayList([]const u8);
const BuildFile = @import("build_file.zig").BuildFile;
const processors = @import("processors.zig");
const util = @import("util.zig");

const logger = std.log.scoped(.obsidian2web);

const PageBuildStatus = enum {
    Unbuilt,
    Built,
    Error,
};

const BuildMetadata = struct {
    html_path: []const u8,
    web_path: []const u8,
    errors: []const u8,
};

const PageState = union(enum) {
    unbuilt: void,
    pre: []const u8,
    main: void,
    post: void,
};

const Page = struct {
    ctx: *const Context,
    filesystem_path: []const u8,
    title: []const u8,
    ctime: i128,

    tags: ?OwnedStringList = null,
    state: PageState = .{ .unbuilt = {} },

    //build_metadata: ?BuildMetadata = null,

    const Self = @This();

    /// assumes given path is a ".md" file.
    pub fn fromPath(ctx: *const Context, fspath: []const u8) !Self {
        const title_raw = std.fs.path.basename(fspath);
        const title = title_raw[0 .. title_raw.len - 3];
        logger.info("new page title='{s}' % {s}", .{ title, fspath });
        var stat = try std.fs.cwd().statFile(fspath);
        return Self{
            .ctx = ctx,
            .filesystem_path = fspath,
            .ctime = stat.ctime,
            .title = title,
        };
    }

    pub fn deinit(self: Self) void {
        if (self.tags) |tags| {
            for (tags.items) |tag| self.ctx.allocator.free(tag);
            tags.deinit();
        }
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return writer.print("Page<path='{s}'>", .{self.filesystem_path});
    }

    pub fn relativePath(self: Self) []const u8 {
        const relative_fspath = std.mem.trimLeft(
            u8,
            self.filesystem_path,
            self.ctx.build_file.vault_path,
        );
        std.debug.assert(relative_fspath[0] != '/'); // must be relative
        return relative_fspath;
    }

    pub fn fetchHtmlPath(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        // output_path = relative_fspath with ".md" replaced to ".html"

        var raw_output_path = try std.fs.path.resolve(
            allocator,
            &[_][]const u8{ "public", self.relativePath() },
        );
        defer allocator.free(raw_output_path);

        return try replaceStrings(
            allocator,
            raw_output_path,
            ".md",
            ".html",
        );
    }

    pub fn fetchWebPath(
        self: Self,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const output_path = try self.fetchHtmlPath(allocator);
        defer allocator.free(output_path);

        // to generate web_path, we need to:
        //  - take html_path
        //  - remove public/
        //  - replace std.fs.path.sep to '/'
        //  - Uri.escapeString

        var trimmed_output_path = std.mem.trimLeft(
            u8,
            output_path,
            "public" ++ std.fs.path.sep_str,
        );

        var trimmed_output_path_2 = try replaceStrings(
            allocator,
            trimmed_output_path,
            std.fs.path.sep_str,
            "/",
        );
        defer allocator.free(trimmed_output_path_2);

        const web_path = try std.Uri.escapeString(allocator, trimmed_output_path_2);
        return web_path;
    }
};

/// Caller owns returned memory.
fn replaceStrings(
    allocator: std.mem.Allocator,
    input: []const u8,
    replace_from: []const u8,
    replace_to: []const u8,
) ![]const u8 {
    const buffer_size = std.mem.replacementSize(
        u8,
        input,
        replace_from,
        replace_to,
    );
    var buffer = try allocator.alloc(u8, buffer_size);
    _ = std.mem.replace(
        u8,
        input,
        replace_from,
        replace_to,
        buffer,
    );

    return buffer;
}

const PageMap = std.StringHashMap(Page);

// article on path a/b/c/d/e.md is mapped as "e" in this title map.
const TitleMap = std.StringHashMap([]const u8);

const PageFile = union(enum) {
    dir: PageFolder,
    file: []const u8,
};

const PageFolder = std.StringHashMap(PageFile);

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

const sepstr = &[_]u8{std.fs.path.sep};

// TODO rename to PathTree
const PageTree = struct {
    allocator: std.mem.Allocator,
    root: PageFolder,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .root = PageFolder.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        deinitPageFolder(&self.root);
    }

    pub fn addPath(self: *Self, fspath: []const u8) !void {
        const total_seps = std.mem.count(u8, fspath, sepstr);
        var path_it = std.mem.split(u8, fspath, sepstr);

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
};

pub const StringBuffer = std.ArrayList(u8);

// TODO move to util

pub const ProcessorContext = struct {
    build_file: *const BuildFile,
    titles: *TitleMap,
    pages: *PageMap,
    captures: []?libpcre.Capture,
    file_contents: []const u8,
    current_page: *Page,
    current_html_path: []const u8,
    allocator: std.mem.Allocator,
};

const Paths = struct {
    /// Path to given page in the web browser
    ///  (must be concatenated with webroot to be correct)
    relative_web_path: []const u8,
    /// Path to given page in the public/ folder (html)
    output_path: []const u8,
};

fn to_hex_digit(digit: u8) u8 {
    return switch (digit) {
        0...9 => '0' + digit,
        10...255 => 'A' - 10 + digit,
    };
}

pub fn parsePaths(local_path: []const u8, string_buffer: []u8) !Paths {
    var fba = std.heap.FixedBufferAllocator{ .buffer = string_buffer, .end_index = 0 };
    var alloc = fba.allocator();

    // local_path contains path to markdown file relative to vault_dir
    //  (so if you want to access it, concatenate vault_dir with local_path)
    //

    // to generate html path, take public/ + local_path, and replace
    // ".md" with ".html"
    const html_path_raw = try std.fs.path.join(alloc, &[_][]const u8{ "public", local_path });
    const offset = std.mem.replacementSize(u8, html_path_raw, ".md", ".html");
    var html_path_buffer = try alloc.alloc(u8, offset);
    _ = std.mem.replace(u8, html_path_raw, ".md", ".html", html_path_buffer);
    const html_path = html_path_buffer[0..offset];

    // to generate web path, we need to:
    //  - take html_path
    //  - remove public/
    //  - replace std.fs.path.sep to '/'
    //  - done!

    const web_path_r1_size = std.mem.replacementSize(u8, html_path, "public" ++ sepstr, "");
    var web_path_r1_buffer = try alloc.alloc(u8, web_path_r1_size);
    _ = std.mem.replace(u8, html_path, "public" ++ sepstr, "", web_path_r1_buffer);
    const web_path_r1 = web_path_r1_buffer[0..web_path_r1_size];

    const web_path_r2_size = std.mem.replacementSize(u8, web_path_r1, sepstr, "/");
    var web_path_r2_buffer = try alloc.alloc(u8, web_path_r2_size);
    _ = std.mem.replace(u8, web_path_r1, sepstr, "/", web_path_r2_buffer);
    const web_path_raw = web_path_r2_buffer[0..web_path_r2_size];

    var result = StringList.init(alloc);
    defer result.deinit();

    for (web_path_raw) |char| {
        switch (char) {
            // safe characters
            '0'...'9',
            'A'...'Z',
            'a'...'z',
            '-',
            '.',
            '_',
            '~',
            std.fs.path.sep,
            => try result.append(char),
            // encode everything else with percent encoding
            else => try result.appendSlice(
                &[_]u8{ '%', to_hex_digit(char >> 4), to_hex_digit(char & 15) },
            ),
        }
    }

    // full web_path does not contain the dot .
    const web_path = std.mem.trimLeft(u8, try result.toOwnedSlice(), ".");

    return Paths{
        .web_path = web_path,
        .html_path = html_path,
    };
}

const SliceList = std.ArrayList([]const u8);

const lexicographicalCompare = struct {
    pub fn inner(innerCtx: void, a: []const u8, b: []const u8) bool {
        _ = innerCtx;

        var i: usize = 0;
        if (a.len == 0 or b.len == 0) return false;
        while (a[i] == b[i]) : (i += 1) {
            if (i == a.len or i == b.len) return false;
        }

        return a[i] < b[i];
    }
}.inner;

fn generatePageTreeHTML(
    writer: anytype,
    ctx: *const Context,
    // TODO TreeGeneratorContext
    tree_context: void,
) !void {
    _ = writer;
    _ = ctx;
    _ = tree_context;
}

const TocContext = struct {
    current_relative_path: ?[]const u8 = null,
    ident: usize = 0,
};

/// Generate Table of Contents given the root folder.
///
/// Operates recursively.
pub fn generateToc(
    result: *StringList,
    build_file: *const BuildFile,
    pages: *const PageMap,
    folder: *const PageFolder,
    context: *TocContext,
    current_page_path: ?[]const u8,
) error{OutOfMemory}!void {
    var folder_iterator = folder.iterator();

    // step 1: find all the folders at this level.

    var folders = SliceList.init(result.allocator);
    defer folders.deinit();

    var files = SliceList.init(result.allocator);
    defer files.deinit();

    while (folder_iterator.next()) |entry| {
        switch (entry.value_ptr.*) {
            .dir => try folders.append(entry.key_ptr.*),
            .file => try files.append(entry.key_ptr.*),
        }
    }

    std.sort.sort([]const u8, folders.items, {}, lexicographicalCompare);
    std.sort.sort([]const u8, files.items, {}, lexicographicalCompare);

    // draw folders first (by recursing), then draw files second!
    var writer = result.writer();
    for (folders.items) |folder_name| {
        try writer.print("<details>", .{});

        const child_folder_entry = folder.getEntry(folder_name).?;
        try result.writer().print(
            "<summary>{s}</summary>\n",
            .{util.unsafeHTML(folder_name)},
        );

        context.ident += 1;
        defer context.ident -= 1;

        try generateToc(result, build_file, pages, &child_folder_entry.value_ptr.*.dir, context, current_page_path);

        try result.writer().print("</details>\n", .{});
    }

    try writer.print("<ul>", .{});
    for (files.items) |file_name| {
        const local_path = folder.get(file_name).?.file;

        var toc_path_buffer: [2048]u8 = undefined;
        const toc_paths = try parsePaths(local_path, &toc_path_buffer);

        const title = std.fs.path.basename(toc_paths.html_path);

        const current_attr = if (current_page_path != null and std.mem.eql(u8, current_page_path.?, toc_paths.web_path))
            "aria-current=\"page\" "
        else
            " ";

        try result.writer().print(
            "<li><a class=\"toc-link\" {s}href=\"{s}{s}\">{s}</a></li>\n",
            .{
                current_attr,
                build_file.config.webroot,
                util.unsafeHTML(toc_paths.web_path),
                util.unsafeHTML(title),
            },
        );
    }
    try result.writer().print("</ul>\n", .{});
}

const FOOTER =
    \\  <footer>
    \\    made with love using <a href="https://github.com/lun-4/obsidian2web">obsidian2web!</a>
    \\  </footer>
;

fn tocForPage(build_file: *BuildFile, pages: *PageMap, tree: *PageTree, current_page: []const u8) ![]const u8 {
    var toc_result = StringList.init(build_file.allocator);
    defer toc_result.deinit();

    var toc_ctx: TocContext = .{};
    try generateToc(
        &toc_result,
        build_file,
        pages,
        &tree.root.getPtr(".").?.dir,
        &toc_ctx,
        current_page,
    );

    return try toc_result.toOwnedSlice();
}

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
    tree: PageTree,

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
            .tree = PageTree.init(allocator),
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

    pub fn pageFromPath(self: Self, path: []const u8) !?Page {
        return self.pages.get(path);
    }

    pub fn pageFromTitle(self: Self, title: []const u8) !?Page {
        return self.pages.get(self.titles.get(title));
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

const ByteList = std.ArrayList(u8);

fn iterateVaultPath(ctx: *Context) !void {
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
        try createStaticResources();

        // for each page
        //  - pass 1: run pre processors (markdown to html)
        //  - pass 2: turn markdown into html (koino)
        //  - pass 3: run post processors

        // TODO rename markdown processors to pre processors.
        var markdown_processors = try initProcessors(MarkdownProcessors);
        defer deinitProcessors(markdown_processors);

        var post_processors = try initProcessors(PostProcessors);
        defer deinitProcessors(post_processors);

        var pages_it = ctx.pages.iterator();
        while (pages_it.next()) |entry| {
            try markdownProcessorPass(&ctx, &markdown_processors, entry.value_ptr);
            try mainPass(&ctx, entry.value_ptr);
            try postProcessorPass(&ctx, &post_processors, entry.value_ptr);
        }
    }
}

const PostProcessors = struct {
    checkmark: processors.CheckmarkProcessor,
    cross_page_link: processors.CrossPageLinkProcessor,
};

const MarkdownProcessors = struct {
    tag: processors.TagProcessor,
};

fn initProcessors(comptime ProcessorHolderT: type) !ProcessorHolderT {
    var proc: ProcessorHolderT = undefined;
    inline for (@typeInfo(ProcessorHolderT).Struct.fields) |field| {
        @field(proc, field.name) = try field.type.init();
    }
    return proc;
}

fn deinitProcessors(procs: anytype) void {
    inline for (@typeInfo(@TypeOf(procs)).Struct.fields) |field| {
        field.type.deinit(@field(procs, field.name));
    }
}

fn Holder(comptime ProcessorT: type, comptime WriterT: type) type {
    return struct {
        ctx: *Context,
        processor: ProcessorT,
        page: *Page,
        last_capture: *?libpcre.Capture,
        out: WriterT,
    };
}

/// This pass will run pre processors only
fn markdownProcessorPass(
    ctx: *Context,
    markdown_processors: anytype,
    page: *Page,
) !void {
    logger.info("pass 1: processing {}", .{page});

    // as these transformers may generate content on top of the page
    // (either markdown or html, i dont care), and we have multiple of them,
    // create a temp file that contains those results

    var markdown_output_path = "/tmp/sex.md"; // fetchTemporaryMarkdownPath();
    defer page.state = .{ .pre = markdown_output_path };

    try std.fs.Dir.copyFile(
        std.fs.cwd(),
        page.filesystem_path,
        std.fs.cwd(),
        markdown_output_path,
        .{},
    );

    inline for (@typeInfo(MarkdownProcessors).Struct.fields) |field| {
        var processor = @field(markdown_processors, field.name);

        //var processor_page_ctx = processor.initForPage();
        //defer processor_page_ctx.deinit();

        const output_file_contents = blk: {
            var output_fd = try std.fs.cwd().openFile(
                markdown_output_path,
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
                markdown_output_path,
                .{ .mode = .write_only },
            );
            defer output_fd.close();
            _ = try output_fd.write(result.items);
        }
    }
}

fn mainPass(ctx: *Context, page: *Page) !void {
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
        .extensions = .{ .autolink = true, .strikethrough = true },
        .render = .{ .hard_breaks = true, .unsafe = true },
    };

    var parser = try koino.parser.Parser.init(ctx.allocator, options);
    defer parser.deinit();

    try parser.feed(input_page_contents);

    var doc = try parser.finish();
    defer doc.deinit();

    // TODO maybe we can just open output file as write only here?

    var result = ByteList.init(ctx.allocator);
    defer result.deinit();
    var output = result.writer();

    // write time
    {
        try writeHead(output, ctx.build_file, page.title);
        // try writePageTree(output, ctx, page);
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

    // write all we got to file
    {
        var html_path = try page.fetchHtmlPath(ctx.allocator);
        defer ctx.allocator.free(html_path);
        logger.info("writing to '{s}'", .{html_path});

        const leading_path_to_file = std.fs.path.dirname(html_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        var output_fd = try std.fs.cwd().createFile(
            html_path,
            .{ .read = false, .truncate = true },
        );
        defer output_fd.close();
        _ = try output_fd.write(result.items);

        page.state = .{ .main = {} };
    }
}

fn postProcessorPass(
    ctx: *Context,
    procs: anytype,
    page: *Page,
) !void {
    logger.info("post: processing {}", .{page});

    std.debug.assert(page.state == .main);
    defer page.state = .{ .post = {} };

    var html_path = try page.fetchHtmlPath(ctx.allocator);
    defer ctx.allocator.free(html_path);

    inline for (@typeInfo(@typeInfo(@TypeOf(procs)).Pointer.child).Struct.fields) |field| {
        var processor = @field(procs, field.name);
        logger.info("running {s} in {}", .{ field.name, page });

        const output_file_contents = blk: {
            var output_fd = try std.fs.cwd().openFile(
                html_path,
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
                html_path,
                .{ .mode = .write_only },
            );
            defer output_fd.close();
            _ = try output_fd.write(result.items);
        }
    }
}

const PageList = std.ArrayList(*const Page);

fn generateTagPages(
    allocator: std.mem.Allocator,
    build_file: BuildFile,
    pages: PageMap,
) !void {
    var tag_map = std.StringHashMap(PageList).init(allocator);

    defer {
        var tags_it = tag_map.iterator();
        while (tags_it.next()) |entry| entry.value_ptr.deinit();
        tag_map.deinit();
    }

    var it = pages.iterator();
    while (it.next()) |entry| {
        var page = entry.value_ptr;
        for (page.tags.items) |tag| {
            var maybe_pagelist = try tag_map.getOrPut(tag);

            if (maybe_pagelist.found_existing) {
                try maybe_pagelist.value_ptr.append(entry.value_ptr);
            } else {
                maybe_pagelist.value_ptr.* = PageList.init(allocator);
                try maybe_pagelist.value_ptr.append(entry.value_ptr);
            }
        }
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

        try writeHead(writer, build_file, tag_name);
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
            // TODO escape data
            var page_fd = try std.fs.cwd().openFile(
                page.filesystem_path,
                .{ .mode = .read_only },
            );
            defer page_fd.close();
            var preview_buffer: [256]u8 = undefined;
            const page_preview_text_read_bytes = try page_fd.read(&preview_buffer);
            const page_preview_text = preview_buffer[0..page_preview_text_read_bytes];
            try writer.print(
                \\ <div class="page-preview">
                \\ 	<a href="{s}{s}">
                \\ 		<div class="page-preview-title"><h2>{s}</h2></div>
                \\ 		<div class="page-preview-text">{s}&hellip;</div>
                \\ 	</a>
                \\ </div><p>
            ,
                .{
                    build_file.config.webroot,
                    page.web_path.?,
                    util.unsafeHTML(page.title),
                    util.unsafeHTML(page_preview_text),
                },
            );
        }

        try writer.print("</div>", .{});

        _ = try writer.write(
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

fn createStaticResources() !void {
    const RESOURCES = .{
        .{ "resources/styles.css", "styles.css" },
        .{ "resources/main.js", "main.js" },
    };

    inline for (RESOURCES) |resource| {
        const resource_text = @embedFile(resource.@"0");

        const output_fspath = "public/" ++ resource.@"1";

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

test "basic test" {
    // _ = std.testing.refAllDecls(@This());
}
