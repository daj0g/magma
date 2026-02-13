#!/bin/bash
set -e

##
# Pre-requirements:
# - env TARGET: path to target work dir
# + env BUG: single bug to apply (default: all if empty)
##

# Apply setup patches
find "${TARGET}/patches/setup" -name "*.patch" | \
while read -r patch; do
    echo "Applying setup patch ${patch}"
    name=${patch##*/}
    name=${name%.patch}
    sed "s/%MAGMA_BUG%/$name/g" "${patch}" | patch -p1 -d "${TARGET}/repo"
done


# Apply bug patches
find "${TARGET}/patches/bugs" -name "*.patch" | \
while read -r patch; do
    name=${patch##*/}
    name=${name%.patch}

    # Simply apply all patches if $BUG is empty
    if [ -z "${BUG}" ]; then
        echo "Applying bug patch ${patch}"
        sed "s/%MAGMA_BUG%/${name}/g" "${patch}" | patch -p1 -d "${TARGET}/repo"
        continue
    fi

    if [ "${BUG}" == "${name}" ]; then
        echo "Applying bug patch ${patch}"
        sed "s/%MAGMA_BUG%/${name}/g" "${patch}" | patch -p1 -d "${TARGET}/repo"
        break
    fi
done