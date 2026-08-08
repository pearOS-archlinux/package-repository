#!/bin/bash

REMOTE_DEST="r2-pearos:package-repo/main/x86_64"
LOCAL_DIR="."

echo "Pushing packages to remote repository..."

rclone sync "$LOCAL_DIR" "$REMOTE_DEST" \
    -L \
    --filter "+ *.pkg.tar.zst*" \
    --filter "+ pearos.db*" \
    --filter "+ pearos.files*" \
    --filter "- push.sh" \
    --filter "- setup_rclone.sh" \
    --filter "- Makefile" \
    --filter "- PKGBUILD" \
    --filter "- *" \
    --progress \
    --delete-after \
    --fast-list

echo "Packages pushed successfully!"
