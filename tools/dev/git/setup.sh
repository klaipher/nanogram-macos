#!/bin/bash
# Registers the repository's git merge and diff drivers in this clone's git config (drivers are not versioned).
# Run once per clone: tools/dev/git/setup.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
git -C "$root" config merge.utf16strings.name "UTF-16 .strings files merged as UTF-8"
git -C "$root" config merge.utf16strings.driver "$root/tools/dev/git/utf16-merge.sh %O %A %B %L %P"
git -C "$root" config diff.utf16.textconv "python3 -I -c 'import sys; sys.stdout.write(open(sys.argv[1], \"rb\").read().decode(\"utf-16\"))'"
git -C "$root" config diff.utf16.binary false
echo "git drivers registered: merge.utf16strings, diff.utf16"
