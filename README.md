# obsidian2web

my obsidian publish knockoff that generates (largely static) websites

this idea came to be from using a notion page for a knowledge index and
seeing absurdly poor performance come out of it. thought i'd make my own to
get my fingers dirty in zig once again.

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
- TODO `strict_links`

build your vault like this

```
./zig-out/bin/obsidian2web path/to/build/file.o2w
```

and now you have a `public/` in your current directory, ready for deploy!
