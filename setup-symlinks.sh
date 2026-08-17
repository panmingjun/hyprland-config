#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config"

link() {
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        rm "$dst"
    elif [ -e "$dst" ]; then
        mv "$dst" "${dst}.bak.$(date +%s)"
    fi
    ln -s "$src" "$dst"
    echo "linked: ${dst} -> ${src}"
}

mkdir -p "${CONFIG_DIR}/dunst"
link "${SRC_DIR}/dunstrc" "${CONFIG_DIR}/dunst/dunstrc"
link "${SRC_DIR}/quickshell" "${CONFIG_DIR}/quickshell"
