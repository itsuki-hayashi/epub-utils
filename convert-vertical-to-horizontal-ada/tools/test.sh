#!/bin/sh
set -eu
python3 "$(dirname "$0")/audit-xml-fork.py"
cd "$(dirname "$0")/../tests"
alr -n build --stop-after=pre-build
alr -n exec -- gprbuild -p -P tests.gpr -XEPUB_PLATFORM=linux -XEPUB_XML_ROLE=tests "$@"
../bin/tests/linux/test-runner
alr -n exec -- gcc -std=c17 -Wall -Wextra -Werror -g -O2 \
  ../tools/test-linux-destination-identity.c ../src/platform/linux/epub_posix.c \
  -Wl,--wrap=stat -Wl,--wrap=statfs -Wl,--wrap=open -Wl,--wrap=ioctl -Wl,--wrap=close \
  -o ../bin/tests/linux/destination-identity
../bin/tests/linux/destination-identity
