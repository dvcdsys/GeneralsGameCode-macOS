#!/usr/bin/env bash
# Install the CWC Guard-From-Position add-on into a Zero Hour / CWC install.
#
# Usage:
#   ./install.sh "<install_root>"
# where <install_root> is the folder containing _469_CWC.big (the CWC .gib)
# and a Data/ subdir.
#
# Purely additive: copies two loose .ini overrides. Uninstall by deleting the
# two _zz_GuardFromPosition.ini files from Data/INI/Override*.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 \"<install_root>\"" >&2
  exit 1
fi

DEST="$1"
SRC="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$DEST" ]; then
  echo "error: install root not found: $DEST" >&2
  exit 1
fi

mkdir -p "$DEST/Data/INI/OverrideCommandButton" \
         "$DEST/Data/INI/OverrideCommandSet"

cp -v "$SRC/Data/INI/OverrideCommandButton/_zz_GuardFromPosition.ini" \
      "$DEST/Data/INI/OverrideCommandButton/"
cp -v "$SRC/Data/INI/OverrideCommandSet/_zz_GuardFromPosition.ini" \
      "$DEST/Data/INI/OverrideCommandSet/"

echo "Installed Guard-From-Position add-on into: $DEST"
