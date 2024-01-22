const std = @import("std");
const libpcre = @import("libpcre");
const testing = @import("testing.zig");
const root = @import("main.zig");
const ProcessorContext = root.ProcessorContext;
const StringBuffer = root.StringBuffer;
const logger = std.log.scoped(.obsidian2web_processors);
const util = @import("util.zig");
const tinymagic = @import("tinymagic.zig");
const Page = @import("Page.zig");

const DefaultRegexOptions = .{ .Ucp = true, .Utf8 = true };

/// Wrap checkmarks in <code> HTML blocks.
pub const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "\\[.\\]";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        const match = captures[0].?;
        const check = file_contents[match.start..match.end];
        try pctx.out.print("<code>{s}</code>", .{check});
    }
};

test "checkmark processor" {
    const TEST_DATA = .{
        .{ "[ ] among us", "<code>[ ]</code> among us" },
        .{ "[x] among us", "<code>[x]</code> among us" },
    };

    try testing.runTestWithDataset(TEST_DATA);
}

pub const CrossPageLinkProcessor = struct {
    const REGEX = "!?\\[\\[.+\\]\\]";

    regex: libpcre.Regex,

    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, .{ .Ucp = true, .Utf8 = true, .Ungreedy = true }),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        const match = captures[0].?;
        const full_link_text = file_contents[match.start..match.end];
        var ctx = pctx.ctx;

        if (full_link_text[0] == '!') {

            // inline link to vault file
            const referenced_file_basename = file_contents[match.start + 3 .. match.end - 2];
            const fspath = ctx.titles.get(referenced_file_basename) orelse {
                logger.err(
                    "referenced name: {s} not found",
                    .{referenced_file_basename},
                );
                return error.InvalidLinksFound;
            };
            const maybe_page = ctx.pages.get(fspath);
            if (maybe_page != null) {
                logger.err(
                    "referenced name: {s} is not an inline-able file, but a page.",
                    .{referenced_file_basename},
                );
                return error.InvalidLinksFound;
            }

            logger.info("inlining media content @ {s}", .{fspath});

            const file_type = try tinymagic.fileTypeFromPath(fspath);

            switch (file_type) {
                .image => try pctx.out.print(
                    "<img src=\"{s}\">",
                    .{
                        ctx.webPath("/images/{s}", .{referenced_file_basename}),
                    },
                ),
                .video => try pctx.out.print(
                    "<video src=\"{s}\" controls>",
                    .{
                        ctx.webPath("/images/{s}", .{referenced_file_basename}),
                    },
                ),
            }
        } else {
            // link to page

            const referenced_title = file_contents[match.start + 2 .. match.end - 2];
            logger.debug(
                "{s} has link to '{s}'",
                .{ pctx.page.title, referenced_title },
            );

            var maybe_page_local_path = ctx.titles.get(referenced_title);
            if (maybe_page_local_path) |page_local_path| {
                var referenced_page = ctx.pages.get(page_local_path).?;
                var web_path = try referenced_page.fetchWebPath(pctx.ctx.allocator);
                defer pctx.ctx.allocator.free(web_path);

                logger.debug(
                    "{s} has link to web path '{s}'",
                    .{ pctx.page.title, web_path },
                );

                try pctx.out.print(
                    "<a href=\"{}\">{s}</a>",
                    .{
                        ctx.webPath("/{s}", .{web_path}),
                        util.unsafeHTML(referenced_title),
                    },
                );
            } else {
                if (ctx.build_file.config.strict_links) {
                    logger.err(
                        "file '{s}' has link to file '{s}' which is not included!",
                        .{ pctx.page, referenced_title },
                    );
                    return error.InvalidLinksFound;
                } else {
                    try pctx.out.print("[[{s}]]", .{referenced_title});
                }
            }
        }
    }
};

test "cross page link processor" {
    const TEST_DATA = .{
        .{ "awooga1", "[[awooga2]]", "<a href=\"/awooga2.html\">awooga2</a>" },
        .{ "awooga2", "[[awooga1]]", "<a href=\"/awooga1.html\">awooga1</a>" },
    };

    const allocator = std.testing.allocator;

    var test_ctx = testing.TestContext.init();
    defer test_ctx.deinit();

    inline for (TEST_DATA) |test_entry| {
        const page_title = test_entry.@"0";
        const page_input = test_entry.@"1";
        try test_ctx.createPage(page_title, page_input);
    }

    try test_ctx.run();

    inline for (TEST_DATA) |test_entry| {
        const page_title = test_entry.@"0";
        const expected_page_output = test_entry.@"2";

        const page = test_ctx.ctx.pageFromTitle(page_title).?;

        const htmlpath = try page.fetchHtmlPath(std.testing.allocator);
        defer std.testing.allocator.free(htmlpath);

        var output_file = try std.fs.cwd().openFile(htmlpath, .{});
        defer output_file.close();
        var output_text = try output_file.reader().readAllAlloc(std.testing.allocator, 1024);
        defer allocator.free(output_text);

        const maybe_found = std.mem.indexOf(u8, output_text, expected_page_output);
        if (maybe_found == null) {
            logger.err("text '{s}' not found in '{s}'", .{
                expected_page_output,
                htmlpath,
            });
        }
        try std.testing.expect(maybe_found != null);
    }
}

pub const TagProcessor = struct {
    regex: libpcre.Regex,

    const REGEX: [:0]const u8 = "#[\\w\\-_]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        var ctx = pctx.ctx;

        const full_match = captures[0].?;
        const raw_text = file_contents[full_match.start..full_match.end];

        // TODO try to do this first_character check in pure regex
        // rather than doing it in code like this lmao

        const first_character = if (full_match.start == 0) ' ' else file_contents[full_match.start - 1];
        if (first_character != ' ' and first_character != '\n') {
            logger.debug("ignoring '{s}' firstchar '{s}'", .{ raw_text, &[_]u8{first_character} });
            return try pctx.out.print("{s}", .{raw_text});
        }

        const tag_text = std.mem.trimLeft(u8, raw_text, " ");
        const tag_name = tag_text[1..];

        // tag index pages will be generated after processor finishes
        var tags = if (pctx.page.tags) |*tags| tags else blk: {
            pctx.page.tags = root.OwnedStringList.init(ctx.allocator);
            break :blk &pctx.page.tags.?;
        };
        try tags.append(try ctx.allocator.dupe(u8, tag_name));

        logger.debug("found tag: text='{s}' name='{s}'", .{ tag_text, tag_name });
        try pctx.out.print(
            "{s}<a href=\"{}\">{s}</a>",
            .{
                if (raw_text[0] == ' ') " " else "",
                ctx.webPath("/_/tags/{s}.html", .{tag_name}),
                tag_text,
            },
        );
    }
};

test "tag processor" {
    const TEST_DATA = .{
        .{ "#awooga", "<a href=\"/_/tags/awooga.html\">#awooga</a>", "awooga" },
    };

    inline for (TEST_DATA) |test_entry| {
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";
        const expected_tag_entry = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, "test", input, expected_output);

        var pages_it = test_ctx.ctx.pages.iterator();
        var page = pages_it.next().?.value_ptr;
        try std.testing.expectEqualSlices(
            u8,
            expected_tag_entry,
            page.tags.?.items[0],
        );
    }
}

// using this because if we dont do it then the tag processor will process
// comments inside code, and we dont want that.
pub const EscapeHashtagsInCode = struct {
    regex: libpcre.Regex,

    const REGEX = "```([\\w\\W]+)```";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        const full_match = captures[0].?;
        const raw_text = file_contents[full_match.start..full_match.end];
        logger.warn("codeblock {s}", .{raw_text});

        try util.fastWriteReplace(pctx.out, raw_text, "#", "&#35;");
    }
};

pub const TableOfContentsProcessor = struct {
    regex: libpcre.Regex,

    const REGEX: [:0]const u8 = "^(#+) [\\S\\-_: ]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{ .regex = try libpcre.Regex.compile(
            REGEX,
            .{ .Ucp = true, .Utf8 = true, .Multiline = true },
        ) };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        var ctx = pctx.ctx;

        const full_match = captures[0].?;
        const raw_text = file_contents[full_match.start..full_match.end];

        const hashtag_match = captures[1].?;
        const hashtag_length = hashtag_match.end - hashtag_match.start;

        const title = raw_text[hashtag_length + 1 ..];
        const web_title_id = util.WebTitlePrinter{ .title = title };

        const level = hashtag_length;

        var titles = if (pctx.page.titles) |*titles| titles else blk: {
            pctx.page.titles = root.OwnedStringList.init(ctx.allocator);
            break :blk &pctx.page.titles.?;
        };

        try titles.append(try ctx.allocator.dupe(u8, title));
        logger.debug("anchor found: {s}", .{title});
        try pctx.out.print(
            // a newline is added after the anchor due to a possible bug in koino
            // where the data after the anchor doesn't get parsed as markdown but instead as raw html
            // (which doesn't work because [links](like these) are not really html tags, just text)
            "<h{d} id=\"{s}\">{s} <a href=\"#{s}\">#</a></h{d}>\n",
            .{ level, web_title_id, title, web_title_id, level },
        );
    }
};

test "table of contents processor" {
    const TEST_DATA = .{
        .{ "# awooga", "<h1 id=\"awooga\">awooga <a href=\"#awooga\">#</a></h1>", "awooga" },
    };

    inline for (TEST_DATA) |test_entry| {
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";
        const expected_title_entry = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, "test", input, expected_output);

        var pages_it = test_ctx.ctx.pages.iterator();
        var page = pages_it.next().?.value_ptr;
        try std.testing.expectEqualSlices(
            u8,
            expected_title_entry,
            page.titles.?.items[0],
        );
    }
}

pub const CodeblockProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "\\`\\`\\`(\\w*)\\n([\\S\\t\\n--]+)\\n\\`\\`\\`";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, .{ .Ucp = true, .Utf8 = true, .Ungreedy = true }),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        const language_match = captures[1].?;
        const code_text_match = captures[2].?;
        const language = file_contents[language_match.start..language_match.end];
        const code_text = file_contents[code_text_match.start..code_text_match.end];
        logger.debug("found lang={s} {s}", .{ language, code_text });

        var ctx = pctx.ctx;
        if (!ctx.build_file.config.code_highlight or language.len == 0) {
            logger.debug("code_hightlight is unset or lang isnt set, ignoring", .{});

            const original_text_match = captures[0].?;
            return try pctx.out.writeAll(
                file_contents[original_text_match.start..original_text_match.end],
            );
        }

        // spit code_text to separate file, feed to pygments
        var file = try std.fs.cwd().createFile("/tmp/o2w_sex2", .{});
        defer file.close();

        try file.writeAll(code_text);

        var argv = root.SliceList.init(ctx.allocator);
        defer argv.deinit();

        try argv.appendSlice(&[_][]const u8{
            "pygmentize",
            "-f",
            "html",
            "-l",
            language,
            "-O",
            "cssclass=pygments",
            "/tmp/o2w_sex2",
        });

        const result = try std.ChildProcess.exec(.{
            .allocator = ctx.allocator,
            .argv = argv.items,
            .max_output_bytes = 100 * 1024,
            .expand_arg0 = .expand,
        });

        defer ctx.allocator.free(result.stdout);
        defer ctx.allocator.free(result.stderr);

        logger.debug(
            "pygments sent stdout {d} bytes, stderr {d} bytes",
            .{ result.stdout.len, result.stderr.len },
        );

        switch (result.term) {
            .Exited => |code| if (code != 0) {
                logger.err("pygmentize returned {} => {s}", .{ code, result.stderr });
                return error.PygmentsFailed;
            },
            else => |code| {
                logger.err("pygmentize returned {} => {s}", .{ code, result.stderr });
                return error.PygmentsFailed;
            },
        }

        logger.debug("pygments output {s}", .{result.stdout});

        return try pctx.out.print("{s}", .{result.stdout});
    }
};

test "code processor" {
    std.testing.log_level = .debug;
    const TEST_DATA = .{
        .{
            \\ ```diff
            \\ - b
            \\ + a
            \\ ```
            ,
            "",
        },
    };

    try testing.runTestWithDataset(TEST_DATA);
}

pub const SetFirstImageProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "!(\\[.*\\]\\((.+)\\)|\\[\\[(.+)\\]\\])";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        const full_match = captures[0].?;
        const full_data = file_contents[full_match.start..full_match.end];
        _ = try pctx.out.write(full_data);

        for (captures, 0..) |maybe_cap, idx| {
            var cap = maybe_cap orelse {
                std.debug.print("cap skip\n", .{});
                continue;
            };
            const text = file_contents[cap.start..cap.end];
            std.debug.print("cap {} idx {d} value {s}\n", .{ cap, idx, text });
        }

        if (pctx.page.maybe_first_image == null) {
            if (std.mem.startsWith(u8, full_data, "![[")) {
                // file from vault
                const url_capture = captures[3].?;
                const ref = file_contents[url_capture.start..url_capture.end];
                const url = try std.fmt.allocPrint(
                    pctx.ctx.allocator,
                    "{}",
                    .{pctx.ctx.webPath("/images/{s}", .{ref})},
                );
                pctx.page.maybe_first_image = url;
            } else {
                // file from url
                const url_capture = captures[2].?;
                const url = file_contents[url_capture.start..url_capture.end];
                pctx.page.maybe_first_image = try pctx.ctx.allocator.dupe(u8, url);
            }
        }
    }
};

pub const StaticTwitterEmbed = struct {
    regex: libpcre.Regex,

    const REGEX = "!twitter\\[(.+)\\]";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;

        const full_match = captures[0].?;
        const ctx = pctx.ctx;

        if (ctx.build_file.config.static_twitter_folder == null) {
            logger.warn("twitter embed requested but no static_twitter_folder provided", .{});
            _ = try pctx.out.write(file_contents[full_match.start..full_match.end]);
            return;
        }

        const static_twitter_folder = ctx.build_file.config.static_twitter_folder.?;
        const twitter_url_match = captures[1].?;
        const twitter_url = file_contents[twitter_url_match.start..twitter_url_match.end];

        var it = std.mem.split(u8, twitter_url, "/");
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        const twitter_id = it.next() orelse return error.InvalidTwitterURL;

        var dir = try std.fs.cwd().openDir(static_twitter_folder, .{});
        defer dir.close();

        var pathbuffer: [std.os.PATH_MAX]u8 = undefined;
        const pathname = try std.fmt.bufPrint(&pathbuffer, "{s}.jsonl", .{twitter_id});
        logger.info("path: {s}", .{pathname});

        var file = dir.openFile(pathname, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                var proc = std.ChildProcess.init(
                    &[_][]const u8{
                        "snscrape",
                        "-vv",
                        "--progress",
                        "--jsonl",
                        "twitter-tweet",
                        "--recurse",
                        twitter_id,
                    },
                    ctx.allocator,
                );
                proc.stdout_behavior = .Pipe;
                //defer proc.kill();
                try proc.spawn();

                var new_file = try dir.createFile(pathname, .{});
                var buf: [512]u8 = undefined;
                while (true) {
                    const read_bytes = try proc.stdout.?.reader().read(&buf);
                    if (read_bytes == 0) break;
                    const data = buf[0..read_bytes];
                    try new_file.writeAll(data);
                }
                const term = try proc.wait();
                logger.info("term: {}", .{term});
                switch (term) {
                    .Exited => |code| switch (code) {
                        0 => {},
                        else => return error.InvalidExitCode,
                    },
                    else => return error.InvalidTermCode,
                }

                try std.os.fsync(new_file.handle);
                new_file.close();

                break :blk try dir.openFile(pathname, .{ .mode = .read_only });
            },
            else => return err,
        };
        defer file.close();

        const snscrape_jsonl = try file.reader().readUntilDelimiterAlloc(ctx.allocator, '\n', std.math.maxInt(usize));
        defer ctx.allocator.free(snscrape_jsonl);

        logger.debug("parsing '{s}'", .{snscrape_jsonl});

        var jsonl_parsed = try std.json.parseFromSlice(SnScrape, ctx.allocator, snscrape_jsonl, .{
            .ignore_unknown_fields = true,
        });
        defer jsonl_parsed.deinit();
        const jsonl_data = jsonl_parsed.value;

        std.debug.assert(std.mem.eql(u8, jsonl_data._type, "snscrape.modules.twitter.Tweet"));

        try pctx.out.print(
            \\<blockquote>
            \\    <p>{s}</p>
        , .{
            jsonl_data.renderedContent,
        });

        if (jsonl_data.media) |all_media| for (all_media) |media| {
            if (std.mem.eql(u8, media._type, "snscrape.modules.twitter.Photo")) {
                var alt_text_buffer: [2048]u8 = undefined;
                const alt_text_html = if (media.altText) |alt_text|
                    try std.fmt.bufPrint(&alt_text_buffer, "alt=\"{s}\"", .{alt_text})
                else
                    "";

                try pctx.out.print(
                    \\ <img src="{s}" {s}></img>
                , .{
                    media.previewUrl orelse continue,
                    alt_text_html,
                });
            }
        };

        try pctx.out.print(
            \\    <p> - <a href="{s}">{s} ({s})</a>, {s}</p>
            \\</blockquote>
        , .{
            twitter_url,
            jsonl_data.user.displayname,
            jsonl_data.user.username,
            jsonl_data.date, // TODO prettyprint date
        });
    }
};

const SnScrape = struct {
    _type: []const u8,
    renderedContent: []const u8,
    date: []const u8,
    user: User,
    media: ?[]Media = null,

    pub const User = struct {
        username: []const u8,
        displayname: []const u8,
    };

    pub const Media = struct {
        _type: []const u8,
        previewUrl: ?[]const u8 = null,
        fullUrl: ?[]const u8 = null,
        altText: ?[]const u8 = null,
    };
};

pub const RecentPagesProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "!recent\\[\\]";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        _ = file_contents;
        _ = captures;
        const ctx = pctx.ctx;

        const PageList = std.ArrayList(*const Page);

        var pages = PageList.init(ctx.allocator);
        defer pages.deinit();
        var it = ctx.pages.iterator();
        while (it.next()) |entry| {
            var page = entry.value_ptr;
            try pages.append(page);
        }

        std.sort.insertion(*const Page, pages.items, {}, struct {
            fn inner(context: void, a: *const Page, b: *const Page) bool {
                _ = context;
                return a.attributes.ctime > b.attributes.ctime;
            }
        }.inner);

        try pctx.out.print("<ul>", .{});

        for (pages.items, 0..) |page, idx| {
            if (idx > 10) break;
            var web_path = try page.fetchWebPath(ctx.allocator);
            defer pctx.ctx.allocator.free(web_path);

            const page_age = page.age();
            const page_age_days = page_age / 86400;

            try pctx.out.print(
                "<li><a href=\"{}\">{s}</a>, last created {d} days ago</li>",
                .{
                    ctx.webPath("/{s}", .{web_path}),
                    util.unsafeHTML(page.title),
                    page_age_days,
                },
            );
        }
        try pctx.out.print("</ul>", .{});
    }
};
