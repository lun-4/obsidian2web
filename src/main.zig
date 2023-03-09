const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

const StringList = std.ArrayList(u8);
const OwnedStringList = std.ArrayList([]const u8);
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
    tags: OwnedStringList,
};

const Page = struct {
    ctx: *const Context,
    filesystem_path: []const u8,
    title: []const u8,
    ctime: i128,

    build_metadata: ?BuildMetadata = null,

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

    pub fn fetchPublicPaths(
        self: Self,
        vault_path: []const u8,
        allocator: std.mem.Allocator,
    ) !Paths {
        // output_path = relative_fspath with ".md" replaced to ".html"
        var raw_output_path = try std.fs.path.resolve(
            allocator,
            &[_][]const u8{ "public", self.relativePath() },
        );
        defer allocator.free(raw_output_path);

        const output_path = try replaceStrings(
            allocator,
            raw_output_path,
            ".md",
            ".html",
        );

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

        const web_path = try Uri.escapeString(allocator, trimmed_output_path_2);
        return .{ .relative_web_path = web_path, .output_path = output_path };
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
    const final_replacement_size = std.mem.replace(
        u8,
        input,
        replace_from,
        replace_to,
        buffer,
    );

    // i'm going to be safe and use std.mem.replace's result, but
    // it should always be the same to replacementSize's count, right?
    std.debug.assert(final_replacement_size == size);
    return try allocator.dupe(u8, buffer[0..final_replacement_size]);
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

fn generatePageTreeHTML(writer: anytype, ctx: *const Context, tree_context: *TreeGeneratorContext) !void {}

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

pub const MatchList = std.ArrayList([]?libpcre.Capture);

pub fn captureAll(
    self: libpcre.Regex,
    allocator: std.mem.Allocator,
    full_string: []const u8,
    options: libpcre.Options,
) (libpcre.Regex.ExecError || std.mem.Allocator.Error)!MatchList {
    var offset: usize = 0;

    var match_list = MatchList.init(allocator);
    errdefer match_list.deinit();
    while (true) {
        var maybe_single_capture = try self.captures(allocator, full_string[offset..], options);
        if (maybe_single_capture) |single_capture| {
            const first_group = single_capture[0].?;
            for (single_capture, 0..) |maybe_group, idx| {
                if (maybe_group != null) {
                    // convert from relative offsets to absolute file offsets
                    single_capture[idx].?.start += offset;
                    single_capture[idx].?.end += offset;
                }
            }
            try match_list.append(single_capture);
            offset += first_group.end;
        } else {
            break;
        }
    }
    return match_list;
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
    vault_dir: std.fs.Dir,
    arenas: ArenaHolder,
    pages: PageMap,
    titles: TitleMap,
    tree: PathTree,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        build_file: BuildFile,
        vault_dir: std.fs.Dir,
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

    pub fn deinit(self: Self) void {
        self.arenas.deinit();
        self.pages.deinit();
        self.titles.deinit();
        self.tree.deinit();
    }

    pub fn addPage(self: *Self, path: []const u8) !void {
        if (!std.mem.endsWith(u8, path, ".md")) return;

        const owned_fspath = try self.arenas.path.allocator().dupe(u8, path);
        var pages_result = self.pages.getOrPut(owned_fspath);
        if (!pages_result.found_existing) {
            var page = try Page.fromPath(self, owned_fspath);
            pages_result.value_ptr.* = page;
            try self.titles.put(page.title, page.fspath);
            try self.tree.addPath(page.fspath);
        }
    }

    pub fn pageFromPath(self: Self, path: []const u8) !?Page {
        return self.pages.get(path);
    }

    pub fn pageFromTitle(self: Self, title: []const u8) !?Page {
        return self.pages.get(self.titles.get(title));
    }
};

fn iterateVaultPath(ctx: *Context) !void {
    for (ctx.build_file.includes.items) |relative_include_path| {
        const absolute_include_path = try std.fs.path.resolve(
            ctx.allocator,
            &[_][]const u8{ build_file.vault_path, relative_include_path },
        );
        defer allocator.free(absolute_include_path);

        logger.info("including given path: '{s}'", .{absolute_include_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openIterableDir(joined_path, .{}) catch |err| switch (err) {
            error.NotDir => {
                try ctx.addPage(absolute_include_path);
                continue;
            },

            else => return err,
        };
        defer included_dir.close();

        // Walker already recurses into all child paths

        var walker = try included_dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .File => {
                    const aboslute_file_path = try std.fs.path.join(
                        ctx.allocator,
                        &[_][]const u8{ absolute_include_path, entry.path },
                    );
                    defer allocator.free(absolute_file_path);
                    try ctx.addPage(absolute_file_path);
                },

                else => {},
            }
        }
    }

    return pages;
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
        //  - pass 1: run markdown processors
        //  - pass 2: turn markdown into html (koino)
        //  - pass 3: turn html into html (html processors)

        try ctx.initMarkdownProcessors();
        var pages_it = ctx.pages.iterator();
        while (pages_it.next()) |entry|
            try markdownProcessorPass(&ctx, entry.value_ptr);
    }
}

const MARKDOWN_PROCESSORS = .{
    processors.TagProcessor,
    processors.CrossPageLinkProcessor,
};

/// This pass will run markdown->markdown processors only
fn markdownProcessorPass(ctx: *Context, page: *const Page) !void {
    logger.info("pass 1: processing {}", .{page});

    // as these transformers may generate content on top of the page
    // (either markdown or html, i dont care), and we have multiple of them,
    // create a temp file that contains those results

    var markdown_output_path = fetchTemporaryMarkdownPath();

    try std.fs.copyFileAbsolute(page.filesystem_path, markdown_output_path);

    for (ctx.markdown_processors) |processor| {
        var processor_page_ctx = processor.initPage();
        defer processor_page_ctx.deinit();

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

        // TODO understand this code

        var regex_offset: usize = 0;
        var last_match: ?libpcre.Capture = null;
        while (true) {
            const text_to_match_against = file_contents[regex_offset..];
            var maybe_single_capture = try processor.regex.captures(
                allocator,
                text_to_match_against,
                .{},
            );
            if (maybe_single_capture) |single_capture| {
                const first_group = single_capture[0].?;

                // convert from relative offsets to absolute file offsets
                // for all captures described in the regex

                for (single_capture, 0..) |maybe_group, idx| {
                    if (maybe_group != null) {
                        single_capture[idx].?.start += offset;
                        single_capture[idx].?.end += offset;
                    }
                }

                // call processor
                last_match = match;
                offset += first_group.end;
            } else {
                break;
            }
        }
        return match_list;
    }
    page.state = .{ .markdown = temporary_markdown_output_path };
}

pub fn oldMain() anyerror!void {
    var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_instance.deinit();

    var alloc = allocator_instance.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();
    const build_file_path = args_it.next() orelse @panic("want build file path");
    defer args_it.deinit();

    const build_file_fd = try std.fs.cwd().openFile(build_file_path, .{ .mode = .read_only });
    defer build_file_fd.close();

    var buffer: [8192]u8 = undefined;
    const build_file_data_count = try build_file_fd.read(&buffer);
    const build_file_data = buffer[0..build_file_data_count];

    var build_file = try BuildFile.parse(alloc, build_file_data);
    defer build_file.deinit();

    var vault_dir = try std.fs.cwd().openIterableDir(build_file.vault_path, .{});
    defer vault_dir.close();

    // TODO move to a Context entity

    var pages = PageMap.init(alloc);
    defer {
        var it = pages.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.tags.items) |owned_string|
                alloc.free(owned_string);
            entry.value_ptr.tags.deinit();
        }

        pages.deinit();
    }

    var titles = TitleMap.init(alloc);
    defer titles.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var string_arena = arena.allocator();

    var tree = PageTree.init(alloc);
    defer tree.deinit();

    // resolve all paths given in include directives into Page entities
    // in the relevant maps (also including title and tree)

    for (build_file.includes.items) |include_path| {
        const joined_path = try std.fs.path.resolve(
            alloc,
            &[_][]const u8{ build_file.vault_path, include_path },
        );
        defer alloc.free(joined_path);

        std.log.info("include path: {s}", .{joined_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openIterableDir(joined_path, .{}) catch |err| switch (err) {
            error.NotDir => {
                const owned_path = try string_arena.dupe(u8, joined_path);
                try addFilePage(
                    &pages,
                    &titles,
                    &tree,
                    include_path,
                    owned_path,
                    alloc,
                );
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
                    try addFilePage(
                        &pages,
                        &titles,
                        &tree,
                        joined_local_inner_path,
                        joined_inner_path,
                        alloc,
                    );
                },

                else => {},
            }
        }
    }

    try std.fs.cwd().makePath("public/");
    try createStaticResources();

    var pages_it = pages.iterator();

    var toc_result = StringList.init(alloc);
    defer toc_result.deinit();

    var toc_ctx: TocContext = .{};
    try generateToc(
        &toc_result,
        &build_file,
        &pages,
        &tree.root.getPtr(".").?.dir,
        &toc_ctx,
        null,
    );

    const toc = try toc_result.toOwnedSlice();
    defer alloc.free(toc);

    // first pass: use koino to parse all that markdown into html
    while (pages_it.next()) |entry| {
        const local_path = entry.key_ptr.*;
        const page = entry.value_ptr.*;
        const fspath = entry.value_ptr.*.filesystem_path;

        std.log.info("processing '{s}'", .{fspath});
        var page_fd = try std.fs.cwd().openFile(
            fspath,
            .{ .mode = .read_only },
        );
        defer page_fd.close();

        const file_contents = try page_fd.reader().readAllAlloc(
            alloc,
            std.math.maxInt(usize),
        );
        defer alloc.free(file_contents);

        var p = try koino.parser.Parser.init(alloc, .{ .unsafe = true });
        defer p.deinit();

        // trying to feed 1k chunks or something is not taken well
        // by the parser.
        try p.feed(file_contents);

        var doc = try p.finish();
        defer doc.deinit();

        var result = StringList.init(alloc);
        defer result.deinit();

        var path_buffer: [2048]u8 = undefined;
        const paths = try parsePaths(local_path, &path_buffer);

        try writeHead(result.writer(), build_file, page.title);

        const pageToc = try tocForPage(
            &build_file,
            &pages,
            &tree,
            paths.web_path,
        );
        defer alloc.free(pageToc);

        try result.appendSlice(pageToc);

        try result.appendSlice(
            \\  </nav>
            \\  <main class="text">
        );

        try result.writer().print(
            \\  <h2>{s}</h2><p>
        , .{util.unsafeHTML(page.title)});

        try koino.html.print(
            result.writer(),
            alloc,
            .{ .render = .{ .hard_breaks = true } },
            doc,
        );

        try result.appendSlice(
            \\  </p></main>
        );

        if (build_file.config.project_footer) {
            try result.appendSlice(FOOTER);
        }

        try result.appendSlice(
            \\  </body>
            \\</html>
        );

        const leading_path_to_file = std.fs.path.dirname(paths.html_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        var output_fd = try std.fs.cwd().createFile(paths.html_path, .{ .read = false, .truncate = true });
        defer output_fd.close();
        _ = try output_fd.write(result.items);

        entry.value_ptr.*.html_path = try string_arena.dupe(u8, paths.html_path);
        entry.value_ptr.*.web_path = try string_arena.dupe(u8, paths.web_path);
        entry.value_ptr.*.status = .Built;
    }
    const link_processor = processors.LinkProcessor{
        .regex = try libpcre.Regex.compile("\\[\\[.+\\]\\]", .{}),
    };
    const check_processor = processors.CheckmarkProcessor{
        .regex = try libpcre.Regex.compile("\\[.\\]", .{}),
    };
    const web_link_processor = processors.WebLinkProcessor{
        .regex = try libpcre.Regex.compile("[> ](https?:\\/\\/[a-zA-Z0-9\\./_\\-#\\?=]+)", .{}),
    };
    const tag_processor = try processors.TagProcessor.init();

    const PROCESSORS = .{
        link_processor,
        check_processor,
        web_link_processor,
        tag_processor,
    };

    // run each processor over the file's contents
    // this generalizes on the regex matching code so that all processors
    // are just called back when we want to get a replacement text on
    // top of them

    comptime var i = 0;
    inline while (i < PROCESSORS.len) : (i += 1) {
        var processor = PROCESSORS[i];
        defer processor.deinit();

        var link_pages_it = pages.iterator();
        while (link_pages_it.next()) |entry| {
            const page = entry.value_ptr.*;
            try std.testing.expectEqual(PageBuildStatus.Built, page.status);
            const html_path = entry.value_ptr.html_path.?;
            logger.info(
                "running {s} for file '{s}'",
                .{ @typeName(@TypeOf(processor)), html_path },
            );

            const file_contents = blk: {
                var page_fd = try std.fs.cwd().openFile(
                    html_path,
                    .{ .mode = .read_only },
                );
                defer page_fd.close();

                break :blk try page_fd.reader().readAllAlloc(
                    alloc,
                    std.math.maxInt(usize),
                );
            };
            defer alloc.free(file_contents);

            const matches = try captureAll(
                processor.regex,
                alloc,
                file_contents,
                .{},
            );
            defer {
                for (matches.items) |match| alloc.free(match);
                matches.deinit();
            }

            var result = StringBuffer.init(alloc);
            defer result.deinit();

            // our replacing algorithm works by copying from 0 to match.start
            // then printing the wanted text
            // our replacing algorithm works by copying from match.end to another_match.start
            // then printing the wanted text
            // etc...
            // note: [[x]] will become <a href="/x">x</a>

            var last_match: ?libpcre.Capture = null;
            for (matches.items) |captures| {
                const match = captures[0].?;
                _ = if (last_match == null)
                    try result.writer().write(
                        file_contents[0..match.start],
                    )
                else
                    try result.writer().write(
                        file_contents[last_match.?.end..match.start],
                    );

                var ctx = ProcessorContext{
                    .build_file = &build_file,
                    .titles = &titles,
                    .pages = &pages,
                    .captures = captures,
                    .file_contents = file_contents,
                    .current_page = entry.value_ptr,
                    .current_html_path = html_path,
                    .allocator = alloc,
                };

                // processor callback is run here!
                try processor.handle(ctx, &result);
                last_match = match;
            }

            // if we're at the end of the file and there's no matches
            // to make anymore, just copy paste the rest

            _ = if (last_match == null)
                try result.writer().write(
                    file_contents[0..file_contents.len],
                )
            else
                try result.writer().write(
                    file_contents[last_match.?.end..file_contents.len],
                );

            {
                var page_fd = try std.fs.cwd().openFile(
                    entry.value_ptr.html_path.?,
                    .{ .mode = .write_only },
                );
                defer page_fd.close();

                _ = try page_fd.write(result.items);
            }
        }
    }

    // generate index file
    {
        const index_out_fd = try std.fs.cwd().createFile(
            "public/index.html",
            .{ .truncate = true },
        );
        defer index_out_fd.close();

        // if an index file was provided in the config, copypaste the resulting
        // HTML as that'll work
        if (build_file.config.index) |path_to_index_file| {
            var path_buffer: [2048]u8 = undefined;
            const paths = try parsePaths(path_to_index_file, &path_buffer);

            std.log.info("copying '{s}' to index.html", .{paths.html_path});
            const index_fd = try std.fs.cwd().openFile(paths.html_path, .{ .mode = .read_only });
            defer index_fd.close();

            const written_bytes =
                try index_fd.copyRangeAll(0, index_out_fd, 0, std.math.maxInt(u64));

            try std.testing.expect(written_bytes > 0);
        } else {
            // if not, generate our own empty file
            // that contains just the table of contents

            const writer = index_out_fd.writer();

            try writeHead(writer, build_file, "Index Page");
            _ = try writer.write(toc);
            try writeEmptyPage(writer, build_file);
        }
    }

    try generateTagPages(alloc, build_file, pages);
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
    _ = std.testing.refAllDecls(@This());
}
