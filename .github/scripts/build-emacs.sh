#!/usr/bin/env bash
# Build Emacs at the emacs-mirror commit EMACS_REF and install it under
# PREFIX.  The build has a window system (X without a toolkit), which the
# canvas image type and the module function `canvas_data' need, PNG
# images and dynamic modules; it is meant for `emacs --batch'.
#
# Usage: EMACS_REF=COMMIT build-emacs.sh PREFIX
# Needs autoconf, texinfo, pkg-config and the development files of
# ncurses, X11, libpng and zlib.
set -euo pipefail

prefix="${1:?usage: EMACS_REF=COMMIT $0 PREFIX}"
ref="${EMACS_REF:?EMACS_REF must name an emacs-mirror commit}"

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT

curl -fsSL --retry 3 "https://github.com/emacs-mirror/emacs/archive/$ref.tar.gz" \
  | tar -xz -C "$src" --strip-components=1
cd "$src"

./autogen.sh
./configure --prefix="$prefix" \
  --without-all \
  --with-x --with-x-toolkit=no \
  --with-modules --with-png --with-zlib \
  --without-native-compilation \
  --disable-build-details
make -j"$(getconf _NPROCESSORS_ONLN)"
make install

"$prefix/bin/emacs" --version
