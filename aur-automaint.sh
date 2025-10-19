#!/bin/bash
# Copyright 2025 Martin Chang
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit

GREEN_ARROW="\033[0;92m=>\033[0m"

help() {
    echo "${1} - automatically maintain a versioned AUR package repository"
    echo "Usage ${1} [options] [--] /path/to/local/repo"
    echo "Options:"
    echo "  -h, --help         Display this help message"
    echo "  -p, --push         Push changes to remote repository"
    echo "  -s, --skip         Skip test building locally"
    echo "  -u, --update-only  Update PKGBUILD only. Do not commit"
    echo "  -f, --force        Skip version check"
}

if [[ $# == 0 ]]; then
    help "${0}"
    exit 1
fi

OPTIONS="h:p:s:u:f"
LONGOPTIONS="help:,push:,skip,update-only:,force"

if PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@") ; then
    eval set -- "$PARSED"
else
    echo >&2
    help "${0}" >&2
    exit 1
fi

repo_path=""
push_to_remote=0
skip_build=0
update_only=0
force=0
while true; do
    case "${1}" in
    -h|--help)
        help "${0}"
        exit 0
        ;;
    -p|--push)
        push_to_remote=1
        shift
        ;;
    -s|--skip)
        skip_build=1
        shift
        ;;
    -u|--update-only)
        update_only=1
        shift
        ;;
    -f|--force)
        force=1
        shift
        ;;
    --)
        shift
    ;;
    *)
        if [[ "$repo_path" != "" ]]; then
            echo "Repository path already specified" >&2
            help "${0}" >&2
            exit 1
        fi
        repo_path="${1}"
        shift
        break
    ;;
    esac
done

if [[ "${repo_path}" == "" ]]; then
    echo "Missing repository path" >&2
    echo >&2
    help "${0}" >&2
    exit 1
fi

if [ ! -d "${repo_path}" ]; then
    echo "cannot access path '${repo_path}' as a directory" >&2
    exit 1
fi

pkgbuild_path="${repo_path}/PKGBUILD"
if [ ! -f "${pkgbuild_path}" ]; then
    echo "cannot access '${pkgbuild_path}' as a file" >&2
    exit 1
fi

source "${pkgbuild_path}"

if [[ ! -v url ]]; then
    echo "PKGBUILD does not contain repository URL" >&2
    exit 1
fi

if [[ ! -v pkgver ]]; then
    echo "PKGBUILD does not contain pkgver" >&2
    exit 1
fi

# pkgname/pkgbase check (I often mess this up)
printf "$GREEN_ARROW Checking PKGBUILD name correctness\n"

repo_real_path="$(realpath ${repo_path})"
dirname="$(basename ${repo_real_path})"

package_name="$pkgbase"
if [[ ! -v pkgbase ]]; then
    package_name="${pkgname}"
fi



if [[ "${dirname}" != "${package_name}" ]]; then
    echo "ERROR! PKGBUILD indicated package name is ${package_name} but lives in directory ${dirname}" >&2
    exit 1
fi
# Check if pkgver is a function on non -git packages (should be string)
declare -f pkgver > /dev/null && pkgvar_is_func=1 || pkgvar_is_func=0
[[ "${dirname}" =~ .*-git.* ]] && is_git_package=1 || is_git_package=0
if [[ "${is_git_package}" == 1 ]] && [[ "${pkgvar_is_func}" == 0 ]]; then
    echo "ERROR! pkgver should be a function in a git package" >&2
    exit 1
fi
if [[ "${is_git_package}" == 0 ]] && [[ "${pkgvar_is_func}" == 1 ]]; then
    echo "ERROR! pkgver should NOT be a function in a non git package" >&2
    exit 1
fi

# Check version
if [[ ! "${url}" =~ https://github.com/.* ]]; then
    echo "ERROR! Invalid repository URL format or not a GitHub URL. Got ${url}" >&2
    exit 1
fi
gh_api_url="${url/github.com/api.github.com\/repos}/releases"
repo_version_string="$(curl --retry 5 --retry-delay 7 -s "$gh_api_url" | jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name' | sed 's/^v//;s/^r//')"

# Version sanity check
if [[ ! "${repo_version_string}" =~ [0-9\\-\\.]+ ]]; then
    echo "ERROR! Weird version string: '${repo_version_string}'. Manual handle needed" >&2
    exit 1
fi

if [[ "${repo_version_string}" == "${pkgver}" ]] && [[ "${force}" == 0 ]]; then
    echo "AUR package version is in sync with repo release. Nothing to do"
    exit 0
fi

printf "$GREEN_ARROW Current package version is ${pkgver}. Repo has version ${repo_version_string}. Updating\n"

provide=""
if [[ -v provides ]]; then
    provide="${provides[0]}"
fi

tmp_file="$(mktemp)"
# edit the PKGBUILD
# 1. Update pkgver
# 2. Set pkgrel to 1 (new version)
# 3. If not -git package, set version for `provides`
printf "${GREEN_ARROW} Updating existing PKGBUILD..\n"
gawk -v newver="${repo_version_string}" -v is_git_package="${is_git_package}" -v pkgver="${pkgver}" -v provide="${provide}" '
    {
        if($0 ~ /^pkgver=/) {
            if(edited) {
                print
                next
            }
            edited=1
            print "pkgver=" newver
        }
        else if($0 ~ /^pkgrel=/) {
            print "pkgrel=1"
        }
        else if($0 ~ /^provides=/ && !is_git_package) {
            print "provides=('\''" provide "=" pkgver "'\'')"
        }
        else {
            print $0
        }
    }
    END{
        if(edited==0) {
            print "ERROR: No replacment happened" > /dev/stderr
            exit 1
        }
    }
' "${pkgbuild_path}" > "${tmp_file}"



mv "${tmp_file}" "${pkgbuild_path}"

(
    if [[ "${skip_build}" -eq 0 ]]; then
        cd "${repo_path}"
        # Clean up previous builds
        rm -r src pkg 2> /dev/null || true
        if ! makepkg -fs --skipchecksums; then
            echo "!!!!!!!!!!!!!! FAILED TO BUILD UPDATED PACKAGE LOCALLY !!!!!!!!!!!!!!" >&2
            echo "Manual intervention needed" >&2
            exit 1
        fi

        # Check if we should update hash
        update_hash=0
        hashtypes=("b2" "sha512" "sha384" "sha256" "sha224" "sha1" "md5" "cksums")
        for type in "${hashtypes[@]}"; do
            varname="${type}sums"
            if [[ ! -v varname ]]; then
                continue
            fi

            for item in "${!varname[@]}"; do
                if [[ "${item}" != "SKIP" ]] && [[ "${item}" != "" ]]; then
                    update_hash=1
                fi
            done
        done
        if [[ "${is_git_package}" == 1 ]]; then
            echo "ERROR: Should NOT update hash for git packages. But values set." >&2
            exit 1
        fi
        if [[ "${update_hash}" -eq 1 ]]; then
            printf "$GREEN_ARROW Updating hash\n"
            updpkgsums
        fi
    fi
)

(
    cd "${repo_path}"
    printf "$GREEN_ARROW Generating .SRCINFO\n"
    makepkg --printsrcinfo > .SRCINFO

    if [[ "${update_only}" -ne 0 ]]; then
        exit 0
    fi

    git add PKGBUILD .SRCINFO
    printf "$GREEN_ARROW Committing changes\n"
    git commit -m "Update PKGBUILD to version ${repo_version_string}"
    if [[ "${push_to_remote}" -ne 0 ]]; then
        printf "$GREEN_ARROW Pushing changes\n"
        git push origin master
    fi
)
