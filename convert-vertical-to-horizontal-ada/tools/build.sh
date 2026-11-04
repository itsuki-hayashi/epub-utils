#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
alr -n build --stop-after=pre-build
build_kind=${EPUB_BUILD:-development}
cpu_tuning=${EPUB_TUNING:-portable}
lto=${EPUB_LTO:-false}
gprof=${EPUB_GPROF:-false}
sections=${EPUB_SECTIONS:-false}
pgo=${EPUB_PGO:-off}
profile_directory=${EPUB_PGO_DIRECTORY:-}
case "$pgo" in off|generate|use) ;; *) echo 'EPUB_PGO must be off, generate or use.' >&2; exit 1 ;; esac
if [ "$pgo" != off ]; then
    if [ "$build_kind" != release ] || [ "$gprof" = true ] || [ "$lto" = true ] || [ -z "$profile_directory" ]; then
        echo 'PGO requires a release build, external EPUB_PGO_DIRECTORY, and no gprof/LTO.' >&2
        exit 1
    fi
    python3 tools/pgo-identity.py "check-$pgo" --project "$PWD" --profile "$profile_directory" --tuning "$cpu_tuning" --sections "$sections"
    profile_directory=$(cd "$profile_directory" && pwd)
elif [ -n "$profile_directory" ]; then
    echo 'EPUB_PGO_DIRECTORY requires EPUB_PGO=generate or use.' >&2
    exit 1
fi
case "$sections" in true|false) ;; *) echo 'EPUB_SECTIONS must be true or false.' >&2; exit 1 ;; esac
if [ "$gprof" = true ] && [ "$build_kind" != profile ]; then
    echo 'Use EPUB_BUILD=profile with EPUB_GPROF=true.' >&2
    exit 1
fi
set -- -p -P epub_v2h_ada.gpr -XEPUB_PLATFORM=linux \
    "-XEPUB_BUILD=$build_kind" "-XEPUB_TUNING=$cpu_tuning" "-XEPUB_SECTIONS=$sections" "-XEPUB_GPROF=$gprof" \
    "-XEPUB_PGO=$pgo" "-XEPUB_PGO_DIRECTORY=$profile_directory" "$@"
suffix=$build_kind-$cpu_tuning
linked_output=false
if [ "$build_kind" != development ] || [ "$cpu_tuning" != portable ] || [ "$lto" = true ] || [ "$gprof" = true ] || [ "$sections" = true ]; then linked_output=true; fi
set -- "$@" "-XEPUB_LINKED_OUTPUT=$linked_output"
if [ "$pgo" != off ]; then set -- "$@" -f; fi
if [ "$lto" = true ]; then suffix=$suffix-lto; fi
if [ "$gprof" = true ]; then suffix=$suffix-gprof; fi
if [ "$sections" = true ]; then suffix=$suffix-sections; fi
if [ "$pgo" != off ]; then suffix=$suffix-pgo-$pgo; fi
build_subdirectory=$suffix
if [ "$linked_output" = true ]; then
    case "$build_kind" in development) build_code=d ;; release) build_code=r ;; profile) build_code=p ;; *) exit 1 ;; esac
    case "$cpu_tuning" in portable) tuning_code=p ;; native) tuning_code=n ;; *) exit 1 ;; esac
    build_subdirectory=$build_code$tuning_code
    if [ "$lto" = true ]; then build_subdirectory=${build_subdirectory}l; fi
    if [ "$gprof" = true ]; then build_subdirectory=${build_subdirectory}g; fi
    if [ "$sections" = true ]; then build_subdirectory=${build_subdirectory}s; fi
fi
if [ "$pgo" != off ]; then build_subdirectory=${build_subdirectory}q; fi
if [ "$linked_output" = true ]; then
    set -- "$@" "--subdirs=$build_subdirectory"
fi
project_directory=$(pwd)
map_directory=bin/linux
if [ "$linked_output" = true ]; then map_directory=obj/linux/linked/$build_subdirectory; fi
set -- "$@" "-XEPUB_LINK_MAP=$project_directory/$map_directory/epub-v2h.map"
ada_flags=
c_flags=
if [ "$build_kind" != development ]; then ada_flags='-O3 -gnatn'; c_flags=-O3; fi
if [ "$cpu_tuning" = native ]; then
    ada_flags="$ada_flags -march=native -mtune=native"
    c_flags="$c_flags -march=native -mtune=native"
fi
if [ "$gprof" = true ]; then ada_flags="$ada_flags -pg"; fi
if [ "$lto" = true ]; then ada_flags="$ada_flags -flto=auto"; fi
if [ "$sections" = true ]; then
    ada_flags="$ada_flags -ffunction-sections -fdata-sections"
    c_flags="$c_flags -ffunction-sections -fdata-sections"
fi
# Only fixed compiler options are split; user paths remain separately quoted.
if [ -n "$ada_flags" ]; then set -- "$@" -cargs:Ada $ada_flags; fi
if [ -n "$c_flags" ]; then set -- "$@" -cargs:C $c_flags; fi
if [ "$lto" = true ]; then set -- "$@" -largs -flto=auto; fi
alr -n exec -- gprbuild "$@"
if [ "$pgo" = generate ]; then
    python3 tools/pgo-identity.py record --project "$PWD" --profile "$profile_directory" --tuning "$cpu_tuning" --sections "$sections"
fi
if [ "$build_kind" = release ]; then
    binary=bin/linux/$suffix/epub-v2h
    linked=obj/linux/linked/$build_subdirectory/epub-v2h
    mkdir -p "$(dirname "$binary")"
    alr -n exec -- objcopy --preserve-dates --only-keep-debug "$linked" "$binary.debug"
    cp "$linked" "$binary"
    cp "$linked.map" "$(dirname "$binary")/epub-v2h.map"
    alr -n exec -- strip --preserve-dates --strip-debug --strip-unneeded "$binary"
elif [ "$linked_output" = true ]; then
    destination=bin/linux/$suffix
    mkdir -p "$destination"
    cp "obj/linux/linked/$build_subdirectory/epub-v2h" "$destination/epub-v2h"
    cp "obj/linux/linked/$build_subdirectory/epub-v2h.map" "$destination/epub-v2h.map"
fi
