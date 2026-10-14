#! /bin/bash
# Starts AktaPrime. Uses the prebuilt system image (sysimage/, see sysimage/build.jl)
# when it exists and is newer than the code; otherwise starts normally, which is
# slower to start, so code changes are never silently ignored.

cd "$(dirname "$0")"
IMAGE=sysimage/AktaPrime.so

if [ -f "$IMAGE" ]; then
    NEWER=$(find src Project.toml Manifest.toml -newer "$IMAGE" -type f | head -1)
    if [ -z "$NEWER" ]; then
        exec julia --sysimage "$IMAGE" --project=. -m AktaPrime /dev/ttyUSB0
    fi
    echo "Note: the system image is older than $NEWER — starting without it."
    echo "      Rebuild it with:  julia --project=sysimage sysimage/build.jl"
fi
exec julia --project=. -m AktaPrime /dev/ttyUSB0
