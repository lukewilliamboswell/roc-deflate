#!/bin/sh
# Build the native macOS host with a pinned, statically linked mimalloc.
set -eu
cd "$(dirname "$0")"
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target=arm64mac ;;
    Darwin-x86_64) target=x64mac ;;
    *) echo 'This build script currently supports native macOS only.' >&2; exit 1 ;;
esac

# Same mimalloc v2.1.7 revision as the retained C/Roc benchmark results.
revision=8c532c32c3c96e5ba1f2283e032f69ead8add00f
sha256=5b419de5ed9273f63b8537d26ff9d49549808224036f483589ed8524a56461f7
mkdir -p .build "targets/$target"
if [ ! -f .build/mimalloc.tar.gz ]; then
    curl -fL --retry 3 "https://codeload.github.com/microsoft/mimalloc/tar.gz/$revision" \
        -o .build/mimalloc.tar.gz.tmp
    mv .build/mimalloc.tar.gz.tmp .build/mimalloc.tar.gz
fi
printf '%s  %s\n' "$sha256" .build/mimalloc.tar.gz | shasum -a 256 -c -
tar -xzf .build/mimalloc.tar.gz -C .build
mimalloc=".build/mimalloc-$revision"
"${CC:-cc}" -std=c11 -O3 -DNDEBUG -DMI_STATIC_LIB -I"$mimalloc/include" \
    -c "$mimalloc/src/static.c" -o "targets/$target/mimalloc.o"
"${CC:-cc}" -std=c11 -O3 -DMI_STATIC_LIB -Wall -Wextra -Werror -I"$mimalloc/include" \
    -c host.c -o "targets/$target/host.o"
cp "$mimalloc/LICENSE" "targets/$target/mimalloc-LICENSE.txt"
printf 'Built %s with mimalloc %s\n' "targets/$target" "$revision"
