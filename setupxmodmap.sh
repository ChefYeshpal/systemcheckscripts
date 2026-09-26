#!/usr/bin/env bash
# setup-xmodmap.sh
#
# Based on the r/linux4noobs "Use xmodmap to map your keys" tutorial.
# Automates: install -> check keys with xev -> dump keymap -> patch a
# keycode -> apply -> persist via ~/.xprofile.
#
# Runs entirely as your normal user. The ONLY step that needs sudo is
# installing the packages, and even that is optional if you already
# have xmodmap/xev installed (common on any Ubuntu desktop install).

set -euo pipefail

XMODMAP_FILE="$HOME/.Xmodmap"
XPROFILE_FILE="$HOME/.xprofile"

# --- 1. Ensure xmodmap + xev are available -----------------------------
# xmodmap comes from x11-xserver-utils, xev comes from x11-utils.
missing_pkgs=()
command -v xmodmap >/dev/null 2>&1 || missing_pkgs+=("x11-xserver-utils")
command -v xev     >/dev/null 2>&1 || missing_pkgs+=("x11-utils")

if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    echo "Missing: ${missing_pkgs[*]}"
    if command -v sudo >/dev/null 2>&1; then
        echo "Installing (requires sudo password)..."
        sudo apt update
        sudo apt install -y "${missing_pkgs[@]}"
    else
        echo "No sudo available on this account."
        echo "Ask an admin to run: sudo apt install ${missing_pkgs[*]}"
        echo "Everything below this point works without sudo once installed."
        exit 1
    fi
else
    echo "xmodmap and xev already installed — no sudo needed."
fi

# --- 2. Optional: identify a key with xev -------------------------------
read -rp "Run 'xev' now to identify a keycode? [y/N] " run_xev
if [[ "$run_xev" =~ ^[Yy]$ ]]; then
    echo "A tiny window will open. Press the key you care about, read the"
    echo "'keycode N' value in the terminal output, then close the window"
    echo "(or Ctrl+C here) to continue."
    xev || true
fi

# --- 3. Back up current keymap, dump full table -------------------------
if [ -f "$XMODMAP_FILE" ]; then
    cp "$XMODMAP_FILE" "$XMODMAP_FILE.bak.$(date +%s)"
    echo "Existing $XMODMAP_FILE backed up."
fi
xmodmap -pke > "$XMODMAP_FILE"
echo "Full keymap dumped to $XMODMAP_FILE"

# --- 4. Patch a specific keycode ----------------------------------------
# Ask which keycode to remap and to what keysym, then edit that one line
# in place (equivalent to the tutorial's manual vim edit).
read -rp "Enter the keycode to remap (blank to skip editing): " target_code
if [ -n "$target_code" ]; then
    read -rp "Enter the keysym it should act as (e.g. Shift_L): " target_sym
    if grep -q "^keycode $target_code " "$XMODMAP_FILE"; then
        sed -i "s/^keycode $target_code .*/keycode $target_code = $target_sym/" "$XMODMAP_FILE"
        echo "Set keycode $target_code = $target_sym in $XMODMAP_FILE"
    else
        echo "keycode $target_code not found in the dumped file — check xev output and re-run."
    fi
fi

# --- 5. Apply now ---------------------------------------------------------
if [ -n "${DISPLAY:-}" ]; then
    if ! xmodmap "$XMODMAP_FILE"; then
        echo "Apply failed — resetting XKB options and retrying once..."
        setxkbmap -option
        xmodmap "$XMODMAP_FILE"
    fi
    echo "Applied to current session."
else
    echo "No DISPLAY set (not in a graphical session) — will apply at next login."
fi

# --- 6. Persist across logins via ~/.xprofile -----------------------------
# .xprofile is read once at login by GDM/LightDM/SDDM etc. This is the
# correct persistence point — no need to touch .bashrc or WM configs,
# since those aren't tied to your X session's key mapping.
load_line="[ -f \"$XMODMAP_FILE\" ] && xmodmap \"$XMODMAP_FILE\""
if ! grep -qF "$load_line" "$XPROFILE_FILE" 2>/dev/null; then
    echo "$load_line" >> "$XPROFILE_FILE"
    chmod +x "$XPROFILE_FILE"
    echo "Added auto-load line to $XPROFILE_FILE"
else
    echo "$XPROFILE_FILE already loads .Xmodmap — skipping."
fi

echo
echo "Done. Log out and back in to confirm the remap survives a restart."
