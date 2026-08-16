#!/usr/bin/env bash
#
# BoonAdvisor uninstaller (Linux / macOS, incl. Steam Deck)
#
# Removes the Import line and the mod folder. The current RoomManager.lua is
# edited in place rather than replaced with the install-time backup, so a game
# updated since installation keeps its updated script.
#
#   ./uninstall.sh
#   ./uninstall.sh /path/to/Hades
#
set -euo pipefail

MARKER='-- BoonAdvisor mod'

green() { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
red()   { printf '  \033[31m[!!]\033[0m %s\n' "$1"; }

printf '\n\033[36mBoonAdvisor uninstaller\033[0m\n\n'

GAME_PATH="${1:-}"

# Search the same places the installer does.
steam_libraries() {
    local roots=(
        "$HOME/.steam/steam"
        "$HOME/.local/share/Steam"
        "$HOME/.steam/root"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"   # flatpak
        "$HOME/Library/Application Support/Steam"                     # macOS
        "/run/media/mmcblk0p1"                                        # Steam Deck SD
    )
    for r in "${roots[@]}"; do
        [ -d "$r" ] && printf '%s\n' "$r"
        # extra library folders declared in libraryfolders.vdf
        local vdf="$r/steamapps/libraryfolders.vdf"
        if [ -f "$vdf" ]; then
            grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" 2>/dev/null \
                | sed -E 's/.*"path"[[:space:]]+"([^"]+)".*/\1/' || true
        fi
    done
}

# On macOS the game's Content lives inside the app bundle, not next to it.
resolve_game_path() {
    local cand="$1"
    if [ -f "$cand/Content/Scripts/RoomManager.lua" ]; then
        printf '%s\n' "$cand"
    elif [ -f "$cand/Game.macOS.app/Contents/Resources/Content/Scripts/RoomManager.lua" ]; then
        printf '%s\n' "$cand/Game.macOS.app/Contents/Resources"
    fi
}

if [ -n "$GAME_PATH" ]; then
    resolved="$(resolve_game_path "$GAME_PATH")"
    [ -n "$resolved" ] && GAME_PATH="$resolved"
else
    while IFS= read -r lib; do
        [ -z "$lib" ] && continue
        resolved="$(resolve_game_path "$lib/steamapps/common/Hades")"
        if [ -n "$resolved" ]; then
            GAME_PATH="$resolved"
            break
        fi
    done < <(steam_libraries | sort -u)
fi

if [ -z "$GAME_PATH" ] || [ ! -f "$GAME_PATH/Content/Scripts/RoomManager.lua" ]; then
    red "Could not find Hades. Re-run as: ./uninstall.sh /path/to/Hades"
    exit 1
fi

ROOM="$GAME_PATH/Content/Scripts/RoomManager.lua"
BACKUP="$ROOM.BoonAdvisorBackup"
MOD_DIR="$GAME_PATH/Content/Mods/BoonAdvisor"

# Strip exactly what the installer appended: the marker line, the Import line,
# and the blank separator line before the marker. Editing in place works no
# matter which game version is installed; restoring the backup would roll
# RoomManager.lua back to the version the game shipped when the mod was first
# installed.
if grep -qF -e "$MARKER" "$ROOM" || grep -qF 'Mods/BoonAdvisor/BoonAdvisor.lua' "$ROOM"; then
    awk -v marker="$MARKER" '
        {
            if (index($0, marker) > 0) {
                if (kept > 0 && (lines[kept] == "" || lines[kept] == "\r")) kept--
                next
            }
            if (index($0, "Mods/BoonAdvisor/BoonAdvisor.lua") > 0) next
            lines[++kept] = $0
        }
        END { for (i = 1; i <= kept; i++) print lines[i] }
    ' "$ROOM" > "$ROOM.tmp"
    mv "$ROOM.tmp" "$ROOM"
    # The game ships RoomManager.lua without a trailing newline and the
    # installer added one (LF, or CRLF from install.ps1) to terminate the last
    # line; the backup shows whether the vanilla file ended without one, so
    # undo it exactly.
    if [ -f "$BACKUP" ] && [ -n "$(tail -c 1 "$BACKUP")" ] && [ -z "$(tail -c 1 "$ROOM")" ]; then
        size=$(wc -c < "$ROOM")
        trim=1
        if [ "$(tail -c 2 "$ROOM")" = "$(printf '\r')" ]; then trim=2; fi
        head -c "$((size - trim))" "$ROOM" > "$ROOM.tmp"
        mv "$ROOM.tmp" "$ROOM"
    fi
    green "Removed the Import line from RoomManager.lua"
else
    green "RoomManager.lua has no BoonAdvisor lines"
fi

if [ -f "$BACKUP" ]; then
    rm -f "$BACKUP"
    green "Removed the install-time backup"
fi

if [ -d "$MOD_DIR" ]; then
    rm -rf "$MOD_DIR"
    green "Removed Content/Mods/BoonAdvisor"
fi

echo
printf '  \033[32mDone. Hades is back to vanilla.\033[0m\n'
echo
