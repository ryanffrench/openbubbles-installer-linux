#!/bin/bash
set -euo pipefail

# --- Configuration ---

INSTALL_DIR="$HOME/opt/openbubbles"
VERSION_FILE="$INSTALL_DIR/.current_version"
SYMLINK_MARKER="$INSTALL_DIR/.created_libmpv_symlink"
REPO="OpenBubbles/openbubbles-app"
BINARY_NAME="bluebubbles"
BINARY="$INSTALL_DIR/$BINARY_NAME"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
DESKTOP_FILE="$HOME/.local/share/applications/openbubbles.desktop"
ICON_FILE="$HOME/.local/share/icons/openbubbles.png"
SCRIPT_INSTALL_PATH="$HOME/.local/bin/openbubbles"
USER_DATA_DIR="$HOME/.local/share/app.bluebubbles.BlueBubbles"

MACHINE=$(uname -m 2>/dev/null || echo "x86_64")
case "$MACHINE" in
    x86_64)  LIB_DIRS="/usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib" ;;
    aarch64) LIB_DIRS="/usr/lib/aarch64-linux-gnu /usr/lib64 /usr/lib" ;;
    armv7l)  LIB_DIRS="/usr/lib/arm-linux-gnueabihf /usr/lib" ;;
    *)       LIB_DIRS="/usr/lib64 /usr/lib" ;;
esac

# Find the actual lib directory containing libmpv runtime libs
# Prioritizes versioned sonames (.so.1, .so.2) over unversioned dev symlinks (.so)
find_lib_dir() {
    # First: check ldconfig cache (most reliable, loader-authoritative)
    local path
    path=$(ldconfig -p 2>/dev/null | grep -E 'libmpv\.so\.[0-9]' | head -1 | sed 's/.*=> //')
    if [ -n "$path" ] && [ -f "$path" ]; then
        dirname "$path"
        return 0
    fi

    # Second: scan known dirs for versioned sonames only
    for dir in $LIB_DIRS; do
        if [ -e "$dir/libmpv.so.1" ] || [ -e "$dir/libmpv.so.2" ]; then
            echo "$dir"
            return 0
        fi
    done

    # Last resort: first existing dir (for pre-install path resolution)
    for dir in $LIB_DIRS; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    echo "/usr/lib"
}

# Detect package manager
detect_pkg_manager() {
    if command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# Per-distro package mapping
# Usage: pkg_install <abstract_name>
# Supported names: jq, libmpv
pkg_install() {
    local name="$1"
    local mgr
    mgr=$(detect_pkg_manager)
    local pkg=""

    case "$name" in
        jq)
            pkg="jq"  # same everywhere
            ;;
        libmpv)
            case "$mgr" in
                apt)     pkg="libmpv2" ;;
                dnf)     pkg="mpv-libs" ;;
                pacman)  pkg="mpv" ;;
                zypper)  pkg="mpv" ;;
                apk)     pkg="mpv-libs" ;;
            esac
            ;;
        *)
            echo "[OpenBubbles] Error: Unknown package name '$name'."
            return 1
            ;;
    esac

    if [ -z "$pkg" ]; then
        echo "[OpenBubbles] Error: No package mapping for '$name' on $mgr."
        echo "[OpenBubbles] Please install libmpv manually."
        return 1
    fi

    case "$mgr" in
        apt)     sudo apt install -y "$pkg" ;;
        dnf)     sudo dnf install -y "$pkg" ;;
        pacman)  sudo pacman -S --noconfirm "$pkg" ;;
        zypper)  sudo zypper install -y "$pkg" ;;
        apk)     sudo apk add "$pkg" ;;
        *)
            echo "[OpenBubbles] Error: Unsupported package manager."
            echo "[OpenBubbles] Please install '$name' manually."
            return 1
            ;;
    esac
}

NONINTERACTIVE=0

# --- Argument preprocessing ---

ARGS=()
for arg in "$@"; do
    case "$arg" in
        --yes|-y) NONINTERACTIVE=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# --- Helpers ---

confirm() {
    local prompt="$1"
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        return 0
    fi
    printf "%s [y/N] " "$prompt"
    read -r answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_self() {
    local target="${1:-$0}"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$target"
    else
        readlink -f "$target"
    fi
}

require_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    echo "[OpenBubbles] jq is required for safe GitHub API parsing."
    if confirm "Install jq?"; then
        pkg_install jq
    else
        echo "[OpenBubbles] Cannot continue without jq."
        exit 1
    fi
}


# --- Cached release info (single API call per invocation) ---

RELEASE_CACHE=""

fetch_release() {
    require_jq

    if [ -z "$RELEASE_CACHE" ]; then
        local http_code
        local tmpfile
        tmpfile=$(mktemp)

        http_code=$(curl -s --connect-timeout 5 --max-time 15 -w "%{http_code}" -o "$tmpfile" "$API_URL" 2>/dev/null || echo "000")
        RELEASE_CACHE=$(cat "$tmpfile" 2>/dev/null || true)
        rm -f "$tmpfile"

        case "$http_code" in
            200) ;;
            000)
                echo "[OpenBubbles] Error: Network failure (DNS, timeout, or no connectivity)."
                RELEASE_CACHE=""
                return 1
                ;;
            403)
                echo "[OpenBubbles] Error: GitHub API rate limit exceeded. Try again later."
                RELEASE_CACHE=""
                return 1
                ;;
            404)
                echo "[OpenBubbles] Error: Release not found. Repository may have moved."
                RELEASE_CACHE=""
                return 1
                ;;
            *)
                echo "[OpenBubbles] Error: GitHub API returned HTTP $http_code."
                RELEASE_CACHE=""
                return 1
                ;;
        esac

        if [ -z "$RELEASE_CACHE" ]; then
            echo "[OpenBubbles] Error: Empty response from GitHub API."
            return 1
        fi
    fi
}

get_latest_tag() {
    fetch_release || return 1
    echo "$RELEASE_CACHE" | jq -r '.tag_name // empty'
}

get_tar_url() {
    fetch_release || return 1
    echo "$RELEASE_CACHE" | jq -r '
        .assets[]
        | select(.name | test("linux.*\\.tar$"; "i"))
        | .browser_download_url
    ' | head -1
}

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

is_installed() {
    [ -x "$BINARY" ]
}

is_running() {
    pgrep -x "$BINARY_NAME" >/dev/null 2>&1
}

# --- Dependency management ---

install_deps() {
    require_jq

    local lib_dir
    lib_dir=$(find_lib_dir)

    # Check if libmpv is available at all (distro-agnostic)
    local has_libmpv=0
    if ldconfig -p 2>/dev/null | grep -q 'libmpv\.so'; then
        has_libmpv=1
    elif [ -e "$lib_dir/libmpv.so" ] || [ -e "$lib_dir/libmpv.so.1" ] || [ -e "$lib_dir/libmpv.so.2" ]; then
        has_libmpv=1
    fi

    if [ "$has_libmpv" -eq 0 ]; then
        echo "[OpenBubbles] libmpv is required for media playback."
        if confirm "Install libmpv?"; then
            pkg_install libmpv
            ldconfig 2>/dev/null || true
            lib_dir=$(find_lib_dir)
        else
            echo "[OpenBubbles] Cannot continue without libmpv."
            exit 1
        fi
    fi

    # Check if the specific soname the app expects (libmpv.so.1) exists
    if [ ! -e "$lib_dir/libmpv.so.1" ]; then
        if [ -e "$lib_dir/libmpv.so.2" ]; then
            echo "[OpenBubbles] libmpv.so.1 not found but libmpv.so.2 exists."
            echo "[OpenBubbles] The app was built against libmpv ABI v1."
            echo "[OpenBubbles] Symlinking .so.2 -> .so.1 may cause runtime crashes if the ABI is incompatible."
            echo "[OpenBubbles] Symlink: $lib_dir/libmpv.so.1 -> libmpv.so.2"
            if confirm "Create symlink anyway? (usually works, but not guaranteed)"; then
                if sudo ln -sf "$lib_dir/libmpv.so.2" "$lib_dir/libmpv.so.1"; then
                    mkdir -p "$INSTALL_DIR"
                    echo "$lib_dir" > "$SYMLINK_MARKER"
                fi
            else
                echo "[OpenBubbles] Cannot continue without libmpv.so.1."
                echo "[OpenBubbles] Try installing an older libmpv package that provides .so.1 directly."
                exit 1
            fi
        else
            echo "[OpenBubbles] Error: libmpv.so found but neither .so.1 nor .so.2 exist."
            echo "[OpenBubbles] You may need to create a symlink manually."
            exit 1
        fi
    fi

    echo "[OpenBubbles] Dependencies ready."
}

# --- Download and extract release ---

download_and_extract() {
    local target_dir="$1"
    local tar_url
    tar_url=$(get_tar_url)

    if [ -z "$tar_url" ]; then
        echo "[OpenBubbles] Error: No matching Linux tar found in release assets."
        exit 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    echo "[OpenBubbles] Downloading from: $tar_url"
    if ! curl -L --fail --connect-timeout 10 --max-time 300 -o "$tmpdir/openbubbles.tar" "$tar_url"; then
        echo "[OpenBubbles] Error: Download failed."
        exit 1
    fi

    echo "[OpenBubbles] Extracting..."
    mkdir -p "$tmpdir/extracted"
    if ! tar -xf "$tmpdir/openbubbles.tar" -C "$tmpdir/extracted"; then
        echo "[OpenBubbles] Error: Extraction failed."
        exit 1
    fi

    # Validate that the expected binary exists in the extracted output
    if [ ! -f "$tmpdir/extracted/$BINARY_NAME" ]; then
        echo "[OpenBubbles] Error: Expected binary '$BINARY_NAME' not found after extraction."
        echo "[OpenBubbles] Archive layout may have changed upstream."
        exit 1
    fi

    # Replace only binary and lib; leave data/ untouched to avoid
    # destroying cache or assets if upstream changes storage location
    mkdir -p "$target_dir"
    rm -rf "${target_dir:?}/$BINARY_NAME" "${target_dir:?}/lib"
    cp -a "$tmpdir/extracted/$BINARY_NAME" "$target_dir/"
    cp -a "$tmpdir/extracted/lib" "$target_dir/"

    # Merge data/ from new release (app assets, not user data)
    if [ -d "$tmpdir/extracted/data" ]; then
        cp -a "$tmpdir/extracted/data" "$target_dir/"
    fi

    chmod +x "$target_dir/$BINARY_NAME"

    trap - EXIT
    rm -rf "$tmpdir"
}

# --- Desktop integration ---

setup_desktop() {
    mkdir -p ~/.local/share/applications ~/.local/share/icons

    if [ -f "$INSTALL_DIR/data/flutter_assets/assets/icon/icon.png" ]; then
        cp "$INSTALL_DIR/data/flutter_assets/assets/icon/icon.png" "$ICON_FILE"
    fi

    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=OpenBubbles
Exec=$SCRIPT_INSTALL_PATH
Icon=$ICON_FILE
Type=Application
Categories=Network;Chat;
StartupWMClass=$BINARY_NAME
EOF

    echo "[OpenBubbles] Desktop entry created."
}

install_script() {
    local self
    self=$(resolve_self)
    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"

    local installed_path
    installed_path=$(resolve_self "$SCRIPT_INSTALL_PATH" 2>/dev/null || true)

    if [ "$self" != "$installed_path" ]; then
        cp "$self" "$SCRIPT_INSTALL_PATH"
        chmod +x "$SCRIPT_INSTALL_PATH"
        echo "[OpenBubbles] Launcher installed to $SCRIPT_INSTALL_PATH"
    fi
}

# --- Install ---

do_install() {
    if is_installed; then
        echo "[OpenBubbles] Already installed at $INSTALL_DIR"
        echo "[OpenBubbles] Use 'openbubbles update' to update."
        exit 0
    fi

    echo "[OpenBubbles] Starting installation..."

    install_deps

    local latest
    latest=$(get_latest_tag)
    if [ -z "$latest" ]; then
        echo "[OpenBubbles] Error: Could not determine latest release."
        exit 1
    fi

    echo "[OpenBubbles] Latest release: $latest"

    download_and_extract "$INSTALL_DIR"
    echo "$latest" > "$VERSION_FILE"

    install_script
    setup_desktop

    echo "[OpenBubbles] Installed $latest to $INSTALL_DIR"
    echo "[OpenBubbles] Run 'openbubbles' to launch."
}

# --- Update ---

do_update() {
    if ! is_installed; then
        echo "[OpenBubbles] Not installed. Run 'openbubbles install' first."
        exit 1
    fi

    echo "[OpenBubbles] Checking for latest release..."

    local latest current
    latest=$(get_latest_tag)
    current=$(get_current_version)

    if [ -z "$latest" ]; then
        echo "[OpenBubbles] Error: Could not determine latest release."
        exit 1
    fi

    echo "[OpenBubbles] Current: $current"
    echo "[OpenBubbles] Latest:  $latest"

    if [ "$latest" = "$current" ]; then
        echo "[OpenBubbles] Already up to date."
        exit 0
    fi

    echo ""
    echo "WARNING: Before updating, export your messages and settings from within the app."
    echo "Your message history is stored in: $USER_DATA_DIR"
    echo "The update replaces application files. A new version may change the database format."

    if ! confirm "Continue with update to $latest?"; then
        echo "[OpenBubbles] Update cancelled."
        exit 0
    fi

    if is_running; then
        echo "[OpenBubbles] Closing running instance..."
        pkill -x "$BINARY_NAME"
        sleep 2
    fi

    download_and_extract "$INSTALL_DIR"
    echo "$latest" > "$VERSION_FILE"

    echo "[OpenBubbles] Updated to $latest successfully."
}

# --- Uninstall ---

do_uninstall() {
    echo "[OpenBubbles] Uninstall will remove:"
    echo "  App files:     $INSTALL_DIR"
    echo "  Launcher:      $SCRIPT_INSTALL_PATH"
    echo "  Desktop entry: $DESKTOP_FILE"
    echo "  Icon:          $ICON_FILE"
    echo ""

    if [ -d "$USER_DATA_DIR" ]; then
        echo "  User data:     $USER_DATA_DIR"
    fi
    echo ""
    echo "  WARNING: This WILL delete all local messages and settings."
    echo ""

    if ! confirm "Proceed with uninstall?"; then
        echo "[OpenBubbles] Uninstall cancelled."
        exit 0
    fi

    if is_running; then
        echo "[OpenBubbles] Closing running instance..."
        pkill -x "$BINARY_NAME"
        sleep 2
    fi

    # Only remove the symlink if we created it (marker stores the lib dir)
    if [ -f "$SYMLINK_MARKER" ]; then
        local symlink_dir
        symlink_dir=$(cat "$SYMLINK_MARKER")
        if [ -n "$symlink_dir" ] && [ -d "$symlink_dir" ] && [ -L "$symlink_dir/libmpv.so.1" ]; then
            echo "[OpenBubbles] Removing libmpv.so.1 compatibility symlink (created during install)."
            sudo rm -f "$symlink_dir/libmpv.so.1"
        fi
    fi

    # Offer to remove libmpv if nothing else needs it
    if confirm "Also remove libmpv? (only do this if no other app needs it)"; then
        local mgr
        mgr=$(detect_pkg_manager)
        case "$mgr" in
            apt)     sudo apt remove -y libmpv2 2>/dev/null || sudo apt remove -y libmpv1 2>/dev/null || true ;;
            dnf)     sudo dnf remove -y mpv-libs 2>/dev/null || true ;;
            pacman)  sudo pacman -Rs --noconfirm mpv 2>/dev/null || true ;;
            zypper)  sudo zypper remove -y mpv 2>/dev/null || true ;;
            *)       echo "[OpenBubbles] Unknown package manager, remove libmpv manually." ;;
        esac
        echo "[OpenBubbles] libmpv removed."
    else
        echo "[OpenBubbles] Keeping libmpv installed."
    fi

    rm -rf "$INSTALL_DIR"
    rm -rf "$USER_DATA_DIR"
    rm -f "$DESKTOP_FILE"
    rm -f "$ICON_FILE"

    echo "[OpenBubbles] Uninstalled."

    # Remove self last
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        rm -f "$SCRIPT_INSTALL_PATH"
        echo "[OpenBubbles] Launcher removed."
    fi
}

# --- Update check (foreground, used at launch) ---

check_for_update() {
    echo "[OpenBubbles] Checking for updates..."
    local latest current
    latest=$(get_latest_tag) || return
    current=$(get_current_version)

    if [ -z "$latest" ]; then
        echo "[OpenBubbles] Could not reach GitHub."
        return
    fi

    echo "[OpenBubbles] Current: $current | Latest: $latest"

    if [ "$latest" != "$current" ]; then
        echo "[OpenBubbles] New version available: $latest"
        echo "[OpenBubbles] Run 'openbubbles update' to update."
    else
        echo "[OpenBubbles] Up to date."
    fi
}

# --- Launch ---

do_launch() {
    if ! is_installed; then
        echo "[OpenBubbles] Not installed."
        if confirm "Install now?"; then
            do_install
        else
            exit 0
        fi
        return
    fi

    case ":${LD_LIBRARY_PATH:-}:" in
        *":$INSTALL_DIR/lib:"*) ;;
        *) export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}" ;;
    esac
    "$BINARY" "$@" >/dev/null 2>&1 &
    disown $!
    (check_for_update) & disown $!
}

# --- Usage ---

usage() {
    echo "Usage: openbubbles [command] [options]"
    echo ""
    echo "Commands:"
    echo "  (none)      Launch OpenBubbles (installs if not present)"
    echo "  install     Install OpenBubbles"
    echo "  update      Update to latest release"
    echo "  uninstall   Remove OpenBubbles"
    echo ""
    echo "Options:"
    echo "  --yes, -y   Skip confirmation prompts"
    echo "  --help, -h  Show this help"
}

# --- Main ---

case "${1:-}" in
    install)
        do_install
        ;;
    update)
        do_update
        ;;
    uninstall)
        do_uninstall
        ;;
    --help|-h)
        usage
        ;;
    *)
        do_launch "$@"
        ;;
esac
