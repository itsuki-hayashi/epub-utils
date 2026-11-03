#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
alr -n build --stop-after=pre-build
alr -n exec -- gprbuild -p -P epub_v2h_ada.gpr -XEPUB_PLATFORM=linux "$@"
