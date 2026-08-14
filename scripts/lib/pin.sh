#!/bin/sh

pin_file=${PIN_FILE:-pins/zed.toml}

pin_value() {
    pin_key=$1
    pin_matches=$(awk -F '[[:space:]]*=[[:space:]]*' -v key="$pin_key" '
        $1 == key {
            value = $2
            sub(/^"/, "", value)
            sub(/"[[:space:]]*$/, "", value)
            print value
        }
    ' "$pin_file")
    pin_count=$(printf '%s\n' "$pin_matches" | awk 'NF { count += 1 } END { print count + 0 }')

    if [ "$pin_count" -ne 1 ]; then
        printf 'expected exactly one %s in %s, found %s\n' "$pin_key" "$pin_file" "$pin_count" >&2
        return 1
    fi

    printf '%s\n' "$pin_matches"
}
