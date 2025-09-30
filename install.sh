#!/bin/bash

# Exit on error
set -e

abort() {
	printf "%s\n" "$@" >&2
	exit 1
}

# Check for bash
if [ -z "${BASH_VERSION:-}" ]; then
	abort "You need use bash to run this script!"
fi

# Check if script is run with force-interactive mode in CI
if [[ -n "${CI-}" && -n "${INTERACTIVE-}" ]]; then
	abort "Cannot run force-interactive mode in CI."
fi

# Check if both `INTERACTIVE` and `NONINTERACTIVE` are set
if [[ -n "${INTERACTIVE-}" && -n "${NONINTERACTIVE-}" ]]; then
	#  shellcheck disable=SC2016
	abort 'Both `$INTERACTIVE` and `$NONINTERACTIVE` are set. Unset at least one variable and try again.'
fi

# Check if script is run in POSIX mode
if [[ -n "${POSIXLY_CORRECT+1}" ]]; then
	abort 'Bash must not run in POSIX mode. Please unset POSIXLY_CORRECT and try again.'
fi

# Variables
REPO_URL="https://github.com/stein935/craft.git" # Replace with actual repo URL
CLI_SCRIPT_NAME="craft"
ARCH="$(/usr/bin/uname -m)"
INSTALL_DIR="/opt"
BIN_DIR="/opt/craft/bin"
SERVER_DIR="/opt/craft/servers"

$1 && echo "Repo URL: $REPO_URL" && echo "CLI Script Name: $CLI_SCRIPT_NAME" && echo "Arch: $ARCH" && echo "Install Dir: $INSTALL_DIR"

# --- System Checks ---

# Check macOS version
MACOS_VERSION=$(sw_vers -productVersion)
REQUIRED_MACOS_VERSION="12.7"
if [[ "$(printf '%s\n' "$REQUIRED_MACOS_VERSION" "$MACOS_VERSION" | sort -V | head -n1)" != "$REQUIRED_MACOS_VERSION" ]]; then
	echo "Error: macOS version must be >= $REQUIRED_MACOS_VERSION. Current version: $MACOS_VERSION"
	exit 1
fi

# Check Java version
REQUIRED_JAVA_VERSION=17
if ! command -v java &>/dev/null; then
	echo "Error: Java is not installed. Please install Java $REQUIRED_JAVA_VERSION or higher."
	exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | awk -F[\".] '/version/ {print $2}')
if [[ "$JAVA_VERSION" -lt $REQUIRED_JAVA_VERSION ]]; then
	echo "Error: Java version must be >= $REQUIRED_JAVA_VERSION. Current version: $(java -version 2>&1 | head -n 1)"
	exit 1
fi

# Check Git installation
if ! command -v git &>/dev/null; then
	echo "Error: Git is not installed. Please install Git before running this script."
	exit 1
fi

# Check for sudo availability and privileges
if ! command -v sudo &>/dev/null; then
	echo "Error: 'sudo' command is not available. Please install sudo and ensure you have admin privileges."
	exit 1
fi

if ! sudo -l mkdir &>/dev/null; then
	echo "Error: You do not have sufficient sudo privileges to install the CLI into /opt/craft."
	echo "This script uses sudo to clone the repository and set permissions in /opt."
	exit
fi

# --- Installation ---

# Clone the CLI repo into lib
if [ ! -d "$INSTALL_DIR/$CLI_SCRIPT_NAME" ]; then
	sudo git clone "$REPO_URL" "$INSTALL_DIR/$CLI_SCRIPT_NAME"
else
	echo "$INSTALL_DIR/$CLI_SCRIPT_NAME already exists"
	exit 1
fi

if [ ! -d "$SERVER_DIR" ]; then
	echo "Creating $SERVER_DIR"
	sudo mkdir "$SERVER_DIR"
fi

# Add bin directory to PATH if not already present
case "${SHELL}" in
*/bash*)
	if [[ -r "${HOME}/.bash_profile" ]]; then
		shell_profile="${HOME}/.bash_profile"
	else
		shell_profile="${HOME}/.profile"
	fi
	;;
*/zsh*)
	shell_profile="${HOME}/.zprofile"
	;;
*)
	shell_profile="${HOME}/.profile"
	;;
esac

if ! grep -q "export PATH.*$BIN_DIR" "$shell_profile"; then
	echo "Adding $BIN_DIR to PATH in $shell_profile"
	echo "export PATH=\"\$PATH:$BIN_DIR\"" >>"$shell_profile"
	echo -e "Added $BIN_DIR to PATH in $shell_profile.\n \
  Restart your terminal or run: source $shell_profile"
fi

echo -e "Installation complete.\n \
  You can now test the CLI using: craft -h"
