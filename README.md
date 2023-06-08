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
  - tested with `0.11.0-dev.1711+dc1f50e50`
- install libpcre in your system
- get [zigmod](https://github.com/nektro/zigmod/releases)

```
git clone https://github.com/lun-4/obsidian2web.git
cd obsidian2web
zigmod fetch
zig build

# for production / release deployments
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSafe
```

# usage

you create an .o2w file with the following text format:

```
vault /home/whatever/path/to/your/obsidian/vault

# include directory1, from the perspective of the vault path
# as in, /home/whatever/path/to/your/obsidian/vault/directory1 MUST exist
include ./directory1
include ./directory2

# it also works with singular files
include ./Some article.md

# if you wish to include the entire vault, do this
include .
```

other directives you might add

- `index ./path/to/some/article.md` to set the index page on your build
  - if not provided, a blank page is used
  - also operates relative to the vault path
- `webroot /path/to/web/thing` to set the deployment location on the web
  - useful if you're deploying to a subfolder of your main domain
- `strict_links yes` or `strict_links no` (default is `yes`)
  - either force all links to exist or let them fail silently (renders as `[[whatever]]` in the output html)
- `project_footer yes` or `project_footer no` (default is `no`)
  - add a small reference to obsidian2web on all the page's footers.
- `custom_css path/to/css/file`
  - use a differentt file for `styles.css` instead of the builtin one

build your vault like this

```
./zig-out/bin/obsidian2web path/to/build/file.o2w
```

and now you have a `public/` in your current directory, ready for deploy!
