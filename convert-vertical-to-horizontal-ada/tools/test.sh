#!/bin/sh
set -eu
cd "$(dirname "$0")/../tests"
alr -n build --stop-after=pre-build
alr -n exec -- gprbuild -p -P tests.gpr -XEPUB_PLATFORM=linux "$@"
../bin/tests/linux/test-runner
