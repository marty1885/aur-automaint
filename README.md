# aur-automaint

Simple shell script that queries release info from GitHub, checks against local AUR repository. Then applies updates if needed

Usage

```
aur-automaint - automatically maintain a versioned AUR package repository
Usage aur-automaint [options] [--] /path/to/local/repo
Options:
  -h, --help         Display this help message
  -p, --push         Push changes to remote repository
  -s, --skip         Skip test building locally
  -u, --update-only  Update PKGBUILD only. Do not commit
  -f, --force        Skip version check
```

Example:

```bash
./aur-automain.sh /path/to/aur-package
```

Dependnencies

* bash
* jq
* curl
* GNU awk
* getopt
* git
* pacman-contrib

How it works

* Reads PKGBUILD
* Query GitHub about the latest release
* Update version info
* Try running `makepkg` see if it builds
* Commit changes or warn you that it fails
