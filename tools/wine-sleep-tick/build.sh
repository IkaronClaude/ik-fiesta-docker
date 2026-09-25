#!/usr/bin/env bash
# Build wine_sleep_tick.so for i386 and x86_64 in a throwaway Ubuntu 24.04 container (the runtime image's base, so
# the glibc matches). Output: out/i386-linux-gnu/wine_sleep_tick.so and out/x86_64-linux-gnu/wine_sleep_tick.so -
# mount them at /usr/lib/<triplet>/wine_sleep_tick.so so LD_PRELOAD='/usr/$LIB/wine_sleep_tick.so' resolves.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
MSYS_NO_PATHCONV=1 docker run --rm -v "$here:/src" ubuntu:24.04 bash -c '
  set -e
  apt-get update -qq >/dev/null
  apt-get install -y -qq gcc gcc-multilib >/dev/null
  mkdir -p /src/out/i386-linux-gnu /src/out/x86_64-linux-gnu
  gcc -O2 -Wall -shared -fPIC -m32 -o /src/out/i386-linux-gnu/wine_sleep_tick.so   /src/wine_sleep_tick.c -ldl
  gcc -O2 -Wall -shared -fPIC -m64 -o /src/out/x86_64-linux-gnu/wine_sleep_tick.so /src/wine_sleep_tick.c -ldl
  ls -la /src/out/*/'
