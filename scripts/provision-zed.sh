#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

. scripts/lib/pin.sh

repository=$(pin_value repository)
tag=$(pin_value tag)
commit=$(pin_value commit)
checkout=.lab/zed

[ ! -L .lab ] || { printf '.lab must not be a symbolic link\n' >&2; exit 1; }
mkdir -p .lab

if [ -e "$checkout" ]; then
    [ ! -L "$checkout" ] || { printf '%s must not be a symbolic link\n' "$checkout" >&2; exit 1; }
    [ -d "$checkout/.git" ] || {
        printf '%s exists but is not a standalone Git checkout\n' "$checkout" >&2
        exit 1
    }
    scripts/check-pin.sh
    printf 'existing Zed checkout already matches the immutable pin\n'
    exit 0
fi

provision_root=$(mktemp -d .lab/provision.XXXXXX)
trap 'rm -rf "$provision_root"' EXIT HUP INT TERM
provision_checkout="$provision_root/zed"

git clone \
    --filter=blob:none \
    --no-checkout \
    --single-branch \
    --branch "$tag" \
    "$repository" \
    "$provision_checkout"

resolved=$(git -C "$provision_checkout" rev-parse "refs/tags/$tag^{commit}")
[ "$resolved" = "$commit" ] || {
    printf 'cloned tag resolved to %s, expected %s\n' "$resolved" "$commit" >&2
    exit 1
}

git -C "$provision_checkout" checkout --detach "$commit"
mv "$provision_checkout" "$checkout"
rmdir "$provision_root"
trap - EXIT HUP INT TERM

scripts/check-pin.sh
printf 'provisioned Zed %s at %s into ignored %s\n' "$tag" "$commit" "$checkout"
