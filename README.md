# aur-automaint

Simple shell script that queries release info from GitHub, checks against local AUR repository. Then applies updates if needed

Usage

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
