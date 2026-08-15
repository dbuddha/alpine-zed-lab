#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

PIN_FILE=pins/alpine.toml
export PIN_FILE
. scripts/lib/pin.sh

repository=$(pin_value repository)
commit=$(pin_value commit)
checkout=.lab/alpine

[ ! -L .lab ] || { printf '.lab must not be a symbolic link\n' >&2; exit 1; }
mkdir -p .lab

if [ -e "$checkout" ]; then
    [ ! -L "$checkout" ] || { printf '%s must not be a symbolic link\n' "$checkout" >&2; exit 1; }
    [ -d "$checkout/.git" ] || {
        printf '%s exists but is not a standalone Git checkout\n' "$checkout" >&2
        exit 1
    }
    scripts/check-alpine-pin.sh
    printf 'existing Alpine checkout already matches the immutable pin\n'
    exit 0
fi

provision_root=$(mktemp -d .lab/alpine-provision.XXXXXX)
trap 'rm -rf "$provision_root"' EXIT HUP INT TERM
provision_checkout="$provision_root/alpine"

git clone --filter=blob:none --no-checkout "$repository" "$provision_checkout"
git -C "$provision_checkout" checkout --detach "$commit"
mv "$provision_checkout" "$checkout"
rmdir "$provision_root"
trap - EXIT HUP INT TERM

scripts/check-alpine-pin.sh
printf 'provisioned Alpine %s into ignored %s\n' "$commit" "$checkout"
