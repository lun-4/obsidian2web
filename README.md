# obsidian2web

my obsidian publish knockoff that generates (largely static) websites

this idea came to be from using a notion page for a knowledge index and
seeing absurdly poor performance come out of it. thought i'd make my own to
get my fingers dirty in zig once again.

you see it in action here: https://l4.pm/vr/lifehax/

(note, do not name any folder inside your vault `public/`, it will break links,
i learned this the hard way. one day i'll fix it.)

# installation

- get a recent master build off https://ziglang.org/download/
  - TODO: get a github release with a musl binary going
- install libpcre in your system
- get [zigmod](https://github.com/nektro/zigmod/releases)

```
git clone https://github.com/lun-4/obsidian2web.git
cd obsidian2web
zigmod fetch
zig build
```

# usage

you create an .o2w file with the following text

```
vault /home/whatever/path/to/your/obsidian/vault
include ./directory1
include ./directory2
include ./Some article.md
```

other directives you might add

- `index ./path/to/some/article.md` to set the index page on your build
  - if not provided, a blank page is used
- `webroot /path/to/web/thing` to set the deployment location on the web
  - useful if you're deploying to a subfolder of your main domain
- `strict_links yes` or `strict_links no` (default is `yes`)
  - either force all links to exist or let them fail silently (renders as `[[whatever]]` in the output html)
- `project_footer yes` or `project_footer no` (default is `no`)
  - add a small reference to obsidian2web on all the page's footers.

build your vault like this

```
./zig-out/bin/obsidian2web path/to/build/file.o2w
```

and now you have a `public/` in your current directory, ready for deploy!
