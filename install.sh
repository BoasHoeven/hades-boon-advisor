#!/usr/bin/env bash
#
# BoonAdvisor installer (Linux / macOS, incl. Steam Deck)
#
# Finds Hades, backs up the one file it edits, copies the mod in, and adds a
# single Import line. Safe to run twice.
#
#   ./install.sh
#   ./install.sh /path/to/Hades
#
set -euo pipefail

MOD_NAME="BoonAdvisor"
IMPORT_LINE='Import "../Mods/BoonAdvisor/BoonAdvisor.lua"'
MARKER='-- BoonAdvisor mod'

green() { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
red()   { printf '  \033[31m[!!]\033[0m %s\n' "$1"; }
step()  { printf '  %s\n' "$1"; }

printf '\n\033[36mBoonAdvisor - Hades boon pick advisor\033[0m\n\n'

# --- 1. Locate Hades ---------------------------------------------------------
GAME_PATH="${1:-}"

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
    red "Could not find your Hades install."
    echo
    echo "  Re-run with the path, for example:"
    echo "    ./install.sh ~/.steam/steam/steamapps/common/Hades"
    echo
    echo "  (The folder that contains Content/Scripts/RoomManager.lua.)"
    exit 1
fi
green "Found Hades: $GAME_PATH"

SCRIPTS="$GAME_PATH/Content/Scripts"
MOD_DIR="$GAME_PATH/Content/Mods/$MOD_NAME"
ROOM="$SCRIPTS/RoomManager.lua"
BACKUP="$ROOM.BoonAdvisorBackup"

if [ ! -w "$ROOM" ]; then
    red "No write permission for $ROOM"
    echo "  Try: sudo ./install.sh \"$GAME_PATH\""
    exit 1
fi

# --- 2. Back up the one vanilla file we touch --------------------------------
if [ ! -f "$BACKUP" ]; then
    cp "$ROOM" "$BACKUP"
    green "Backed up RoomManager.lua"
elif ! grep -qF -e "$MARKER" "$ROOM"; then
    # The live file has no import line, so a game update or Steam file
    # verification replaced it since the backup was made. The current file is
    # this game version's vanilla script; keeping the old backup would roll
    # the game back to a previous patch on uninstall.
    cp "$ROOM" "$BACKUP"
    green "Refreshed the backup (game files changed since the last install)"
else
    step "Backup already exists, keeping the original one"
fi

# --- 3. Copy the mod ---------------------------------------------------------
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mod"
if [ ! -d "$SRC" ]; then
    red "Can't find the 'mod' folder next to this script."
    exit 1
fi
mkdir -p "$MOD_DIR"
cp "$SRC"/*.lua "$MOD_DIR"/
green "Installed $(ls -1 "$MOD_DIR"/*.lua | wc -l | tr -d ' ') Lua files to Content/Mods/$MOD_NAME"

# --- 4. Add the Import line (idempotent) -------------------------------------
if grep -qF -e "$MARKER" "$ROOM"; then
    step "Import line already present"
else
    # Ensure a trailing newline before appending.
    [ -n "$(tail -c 1 "$ROOM")" ] && printf '\n' >> "$ROOM"
    printf '\n%s\n%s\n' "$MARKER" "$IMPORT_LINE" >> "$ROOM"
    green "Added the Import line to RoomManager.lua"
fi

# --- 5. Verify ---------------------------------------------------------------
if grep -qF -e "$IMPORT_LINE" "$ROOM" && [ -f "$MOD_DIR/BoonAdvisor.lua" ]; then
    echo
    printf '  \033[32mDone. Start Hades and take a boon.\033[0m\n'
    echo "  Ranks appear on boons, hammers, Poms, Chaos, doors, the shop and keepsakes."
    echo
    echo "  To remove it later: ./uninstall.sh"
    echo
else
    red "Verification failed - the mod may not be installed correctly."
    exit 1
fi
