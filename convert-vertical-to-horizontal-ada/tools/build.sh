#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
alr -n build --stop-after=pre-build
build_kind=${EPUB_BUILD:-development}
cpu_tuning=${EPUB_TUNING:-portable}
lto=${EPUB_LTO:-false}
gprof=${EPUB_GPROF:-false}
if [ "$gprof" = true ] && [ "$build_kind" != profile ]; then
    echo 'Use EPUB_BUILD=profile with EPUB_GPROF=true.' >&2
    exit 1
fi
set -- -p -P epub_v2h_ada.gpr -XEPUB_PLATFORM=linux \
    "-XEPUB_BUILD=$build_kind" "-XEPUB_TUNING=$cpu_tuning" "$@"
suffix=$build_kind-$cpu_tuning
if [ "$build_kind" = release ]; then set -- "$@" -XEPUB_LINKED_OUTPUT=true; fi
if [ "$lto" = true ]; then suffix=$suffix-lto; fi
if [ "$gprof" = true ]; then suffix=$suffix-gprof; fi
if [ "$build_kind" != development ] || [ "$cpu_tuning" != portable ] || [ "$lto" = true ] || [ "$gprof" = true ]; then
    set -- "$@" "--subdirs=$suffix"
fi
ada_flags=
c_flags=
if [ "$build_kind" != development ]; then ada_flags='-O3 -gnatn'; c_flags=-O3; fi
if [ "$cpu_tuning" = native ]; then
    ada_flags="$ada_flags -march=native -mtune=native"
    c_flags="$c_flags -march=native -mtune=native"
fi
if [ "$gprof" = true ]; then ada_flags="$ada_flags -pg"; fi
if [ "$lto" = true ]; then ada_flags="$ada_flags -flto=auto"; fi
# Only fixed compiler options are split; user paths remain separately quoted.
if [ -n "$ada_flags" ]; then set -- "$@" -cargs:Ada $ada_flags; fi
if [ -n "$c_flags" ]; then set -- "$@" -cargs:C $c_flags; fi
if [ "$lto" = true ]; then set -- "$@" -largs -flto=auto; fi
alr -n exec -- gprbuild "$@"
if [ "$build_kind" = release ]; then
    binary=bin/linux/$suffix/epub-v2h
    linked=obj/linux/linked/$suffix/epub-v2h
    mkdir -p "$(dirname "$binary")"
    alr -n exec -- objcopy --preserve-dates --only-keep-debug "$linked" "$binary.debug"
    cp "$linked" "$binary"
    cp "$linked.map" "$(dirname "$binary")/epub-v2h.map"
    alr -n exec -- strip --preserve-dates --strip-debug --strip-unneeded "$binary"
fi
