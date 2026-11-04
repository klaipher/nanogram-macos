#!/bin/bash
# Git merge driver for UTF-16 .strings files (Telegram-Mac/*.lproj/Localizable.strings).
# Git sees these files as binary, so every upstream string change plus any edit of ours conflicts as a whole file.
# This driver converts the three versions to UTF-8, merges them line by line with `git merge-file` and writes the
# result back as UTF-16LE with a byte order mark. Exit status is merge-file's: 0 clean, >0 conflicts (markers in the file).
#
# Usage (git passes it): utf16-merge.sh <base %O> <ours %A> <theirs %B> [marker size %L] [path %P]
# Registered by tools/dev/git/setup.sh (merge drivers live in git config, not in the repository).
set -euo pipefail

base="$1"; ours="$2"; theirs="$3"; marker="${4:-7}"; path="${5:-Localizable.strings}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Python does the conversion: it reads the BOM-prefixed UTF-16 files strictly, which the system iconv does not.
to_utf8() { python3 -I -c 'import sys; open(sys.argv[2], "w", encoding="utf-8", newline="").write(open(sys.argv[1], "rb").read().decode("utf-16"))' "$1" "$2"; }
to_utf16() { python3 -I -c 'import sys; open(sys.argv[2], "wb").write(b"\xff\xfe" + open(sys.argv[1], "r", encoding="utf-8", newline="").read().encode("utf-16-le"))' "$1" "$2"; }

to_utf8 "$base" "$tmp/base"
to_utf8 "$ours" "$tmp/ours"
to_utf8 "$theirs" "$tmp/theirs"

status=0
git merge-file --marker-size="$marker" -L "ours" -L "base" -L "theirs" "$tmp/ours" "$tmp/base" "$tmp/theirs" || status=$?
if [ "$status" -ge 128 ]; then
    echo "utf16-merge: git merge-file failed for $path" >&2
    exit 1
fi
to_utf16 "$tmp/ours" "$ours"
exit "$status"
