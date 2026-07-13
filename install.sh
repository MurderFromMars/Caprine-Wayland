#!/usr/bin/env bash
#
# install.sh — build Caprine-Wayland from source and install it.
#
# Builds an AppImage via electron-builder and installs it (plus a .desktop
# entry and icon) either for the current user (default, no root needed) or
# system-wide with --system.
#
# Usage:
#   ./install.sh                # build + install for current user
#   ./install.sh --system       # build + install system-wide (needs sudo)
#   ./install.sh --deb          # build a .deb instead of an AppImage
#   ./install.sh --uninstall    # remove a previous install
#   ./install.sh --skip-deps    # don't try to install missing system packages
#   ./install.sh -h | --help

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

APP_NAME="caprine-wayland"
APP_DISPLAY_NAME="Caprine Wayland"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="AppImage"
MODE="user"
SKIP_DEPS=0
DO_UNINSTALL=0
MIN_NODE_MAJOR=16

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
	C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
	C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

info()  { printf '%s[*]%s %s\n' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$1"; }
ok()    { printf '%s[+]%s %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1"; }
warn()  { printf '%s[!]%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$1"; }
fail()  { printf '%s[x]%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

print_help() {
	sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--system) MODE="system" ;;
		--user) MODE="user" ;;
		--deb) TARGET="deb" ;;
		--appimage) TARGET="AppImage" ;;
		--skip-deps) SKIP_DEPS=1 ;;
		--uninstall) DO_UNINSTALL=1 ;;
		-h|--help) print_help; exit 0 ;;
		*) fail "Unknown argument: $1 (see --help)" ;;
	esac
	shift
done

if [[ "$MODE" == "system" ]]; then
	BIN_DIR="/usr/local/bin"
	INSTALL_DIR="/opt/${APP_NAME}"
	DESKTOP_DIR="/usr/share/applications"
	ICON_DIR="/usr/share/icons/hicolor/512x512/apps"
	SUDO="sudo"
else
	BIN_DIR="${HOME}/.local/bin"
	INSTALL_DIR="${HOME}/.local/share/${APP_NAME}"
	DESKTOP_DIR="${HOME}/.local/share/applications"
	ICON_DIR="${HOME}/.local/share/icons/hicolor/512x512/apps"
	SUDO=""
fi

DESKTOP_FILE="${DESKTOP_DIR}/${APP_NAME}.desktop"
ICON_FILE="${ICON_DIR}/${APP_NAME}.png"
WRAPPER="${BIN_DIR}/${APP_NAME}"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
	info "Removing ${APP_DISPLAY_NAME} (${MODE} install)…"
	$SUDO rm -rf "$INSTALL_DIR"
	$SUDO rm -f "$WRAPPER" "$DESKTOP_FILE" "$ICON_FILE"
	if command -v update-desktop-database >/dev/null 2>&1; then
		$SUDO update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
	fi
	ok "Uninstalled."
	exit 0
fi

# ---------------------------------------------------------------------------
# Dependency detection / install
# ---------------------------------------------------------------------------

pkg_manager=""
if command -v pacman >/dev/null 2>&1; then pkg_manager="pacman"
elif command -v apt-get >/dev/null 2>&1; then pkg_manager="apt"
elif command -v dnf >/dev/null 2>&1; then pkg_manager="dnf"
elif command -v zypper >/dev/null 2>&1; then pkg_manager="zypper"
fi

install_system_deps() {
	if [[ "$SKIP_DEPS" -eq 1 ]]; then
		warn "Skipping system dependency install (--skip-deps)."
		return
	fi

	case "$pkg_manager" in
		pacman)
			info "Installing build deps via pacman…"
			sudo pacman -S --needed --noconfirm base-devel git nodejs npm python
			;;
		apt)
			info "Installing build deps via apt…"
			sudo apt-get update
			sudo apt-get install -y build-essential git nodejs npm python3
			;;
		dnf)
			info "Installing build deps via dnf…"
			sudo dnf install -y @development-tools git nodejs npm python3
			;;
		zypper)
			info "Installing build deps via zypper…"
			sudo zypper install -y -t pattern devel_basis
			sudo zypper install -y git nodejs npm python3
			;;
		*)
			warn "Unknown package manager — skipping automatic dependency install."
			warn "Make sure git, a C/C++ toolchain, python3, node (>=${MIN_NODE_MAJOR}) and npm are installed."
			;;
	esac
}

check_deps() {
	local missing=()
	for cmd in git node npm python3; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		warn "Missing: ${missing[*]}"
		install_system_deps
	fi

	command -v node >/dev/null 2>&1 || fail "node is still missing after dependency install — install it manually and re-run."
	command -v npm  >/dev/null 2>&1 || fail "npm is still missing after dependency install — install it manually and re-run."

	local node_major
	node_major="$(node -p 'process.versions.node.split(".")[0]')"
	if (( node_major < MIN_NODE_MAJOR )); then
		fail "node ${MIN_NODE_MAJOR}+ required, found $(node -v). Upgrade node and re-run."
	fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build() {
	cd "$REPO_DIR"

	info "Installing npm dependencies (this also patches deps + preps electron-builder)…"
	if [[ -f package-lock.json ]]; then
		npm ci
	else
		npm install
	fi

	info "Compiling TypeScript…"
	npm run build

	info "Packaging ${TARGET} with electron-builder (this can take a while on first run)…"
	npx electron-builder --linux "$TARGET"

	ok "Build complete."
}

# ---------------------------------------------------------------------------
# Install built artifact
# ---------------------------------------------------------------------------

install_artifact() {
	cd "$REPO_DIR"

	mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
	if [[ "$MODE" == "system" ]]; then
		sudo mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
	fi

	if [[ "$TARGET" == "AppImage" ]]; then
		local appimage
		appimage="$(find dist -maxdepth 1 -iname '*.AppImage' | head -n1)"
		[[ -n "$appimage" ]] || fail "No AppImage found in dist/ — build must have failed."

		info "Installing AppImage to ${INSTALL_DIR}…"
		$SUDO install -m 755 "$appimage" "${INSTALL_DIR}/${APP_NAME}.AppImage"

		info "Creating launcher at ${WRAPPER}…"
		$SUDO tee "$WRAPPER" >/dev/null <<EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/${APP_NAME}.AppImage" --no-sandbox "\$@"
EOF
		$SUDO chmod 755 "$WRAPPER"
	else
		local deb
		deb="$(find dist -maxdepth 1 -iname '*.deb' | head -n1)"
		[[ -n "$deb" ]] || fail "No .deb found in dist/ — build must have failed."
		command -v dpkg >/dev/null 2>&1 || fail "--deb requires dpkg to install the package."

		info "Installing ${deb} via dpkg…"
		sudo dpkg -i "$deb" || sudo apt-get install -f -y
		# The .deb package already ships its own binary, desktop entry, and
		# icon (installed as 'caprine'), so there's nothing further to do.
		ok "Installed via dpkg as 'caprine'. Skipping manual desktop/icon setup."
		return
	fi

	info "Installing icon and desktop entry…"
	$SUDO install -m 644 "build/icons/512x512.png" "$ICON_FILE"

	$SUDO tee "$DESKTOP_FILE" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=${APP_DISPLAY_NAME}
Comment=Elegant Facebook Messenger desktop app (Wayland-native fork)
Exec=${WRAPPER} %U
Icon=${APP_NAME}
Categories=Network;Chat;
Terminal=false
StartupWMClass=Caprine
EOF

	if command -v update-desktop-database >/dev/null 2>&1; then
		$SUDO update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		$SUDO gtk-update-icon-cache -f "$(dirname "$(dirname "$ICON_DIR")")" >/dev/null 2>&1 || true
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

info "Installing ${APP_DISPLAY_NAME} (${MODE} mode, target: ${TARGET})"
check_deps
build
install_artifact

ok "Done. Launch it with '${APP_NAME}' or from your app launcher."
if [[ "$MODE" == "user" ]]; then
	case ":$PATH:" in
		*":${BIN_DIR}:"*) ;;
		*) warn "${BIN_DIR} isn't on your PATH — add it, or launch from your desktop menu." ;;
	esac
fi
info "Wayland is auto-detected at launch (XDG_SESSION_TYPE / WAYLAND_DISPLAY)."
info "Force it with CAPRINE_FORCE_WAYLAND=1, or disable with CAPRINE_DISABLE_WAYLAND=1."
