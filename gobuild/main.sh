#!/usr/bin/env bash
# gobuild - portable go build: static (CGO_ENABLED=0), stripped, cross-arch aware
#
# Usage:
#   gobuild [root] [target] [arch] [-o output]
#
#   root    path to the go project root (default: .)
#           package to build is auto-resolved under it, see below
#   target  linux | android (default: linux)
#   arch    amd64 | 386 | arm64 (x86 is an alias for 386; default: native GOARCH)
#   -o      output binary path (default: <root>/bin/<name>, else <root>/../bin/<name>, else <root>/<name>)
#
# Package resolution under <root>:
#   1. <root>/main.go                        (root package)
#   2. <root>/cmd/<basename of root>/main.go  (cmd dir matching repo name)
#   3. the single subdir under <root>/cmd/    (only if exactly one exists)
#   4. recursive search for the single main.go under <root>
#      (searched from <root>/.. instead when root's basename is "bin")
#   otherwise: fail and list matches so you can pass a package explicitly

set -euo pipefail

root="."
target="linux"
arch="$(go env GOARCH)"
output=""
variant_specified=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        linux|android)
            target="$1"
            variant_specified=true
            shift
            ;;
        termux)
            target="android"
            arch="arm64"
            variant_specified=true
            shift
            ;;
        amd64|x86_64)
            arch="amd64"
            variant_specified=true
            shift
            ;;
        386|x86)
            arch="386"
            variant_specified=true
            shift
            ;;
        arm64|aarch64)
            arch="arm64"
            variant_specified=true
            shift
            ;;
        *)
            root="${1%/}"
            shift
            ;;
    esac
done

name="$(basename "$(cd "$root" && pwd)")"

if [[ -f "$root/main.go" ]]; then
    pkg="$root"
elif [[ -f "$root/cmd/$name/main.go" ]]; then
    pkg="$root/cmd/$name"
elif [[ -d "$root/cmd" ]]; then
    subdirs=("$root"/cmd/*/)
    if [[ ${#subdirs[@]} -eq 1 ]]; then
        pkg="${subdirs[0]%/}"
    else
        echo "gobuild: can't resolve package — multiple dirs under $root/cmd/:" >&2
        printf '  %s\n' "${subdirs[@]%/}" >&2
        echo "pass one explicitly: gobuild $root/cmd/<name>" >&2
        exit 1
    fi
else
    search_root="$root"
    [[ "$name" == "bin" && -d "$root/.." ]] && search_root="$root/.."

    mains=()
    while IFS= read -r -d '' f; do
        mains+=("$f")
    done < <(find "$search_root" \( -name node_modules -o -name vendor -o -name .git \) -prune -o -name main.go -print0)

    if [[ ${#mains[@]} -eq 1 ]]; then
        pkg="$(dirname "${mains[0]}")"
    elif [[ ${#mains[@]} -eq 0 ]]; then
        echo "gobuild: no main.go found under $search_root — pass a package path explicitly" >&2
        exit 1
    else
        echo "gobuild: can't resolve package — multiple main.go found under $search_root:" >&2
        printf '  %s\n' "${mains[@]}" >&2
        echo "pass one explicitly: gobuild <path/to/pkg>" >&2
        exit 1
    fi
fi

if [[ -z "$output" ]]; then
    if [[ "$pkg" == "$root" ]]; then
        pkgname="$name"
    else
        pkgname="$(basename "$pkg")"
    fi

    if [[ -d "$root/bin" ]]; then
        bindir="$root/bin"
    elif [[ -d "$root/../bin" ]]; then
        bindir="$root/../bin"
    else
        bindir="$root"
    fi
    if [[ "$variant_specified" == true ]]; then
        if [[ "$target" == "android" ]]; then
            suffix="android-$arch"
        else
            suffix="$arch"
        fi
        output="$bindir/$pkgname-$suffix"
    else
        output="$bindir/$pkgname"
    fi
fi

# go.mod is looked up from the process's cwd, not from the package path, so
# when $pkg lives outside the caller's directory tree (e.g. gobuild ../backend)
# we must -C into the module root or `go build` can't find go.mod at all.
abspkg="$(cd "$pkg" && pwd)"
modroot="$abspkg"
while [[ ! -f "$modroot/go.mod" && "$modroot" != "/" ]]; do
    modroot="$(dirname "$modroot")"
done
if [[ ! -f "$modroot/go.mod" ]]; then
    echo "gobuild: no go.mod found above $abspkg" >&2
    exit 1
fi

if [[ "$abspkg" == "$modroot" ]]; then
    pkgrel="."
else
    pkgrel="./${abspkg#"$modroot"/}"
fi

mkdir -p "$(dirname "$output")"
outdir="$(cd "$(dirname "$output")" && pwd)"
absoutput="$outdir/$(basename "$output")"

buildmode=()
if [[ "$target" == "android" ]]; then
    buildmode=(-buildmode=pie)
fi

echo "gobuild: GOOS=$target GOARCH=$arch pkg=$pkgrel (root=$modroot) -o $absoutput" >&2
CGO_ENABLED=0 GOOS="$target" GOARCH="$arch" go -C "$modroot" build "${buildmode[@]}" -ldflags="-s -w" -o "$absoutput" "$pkgrel"
