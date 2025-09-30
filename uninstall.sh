#!/bin/bash

declare -a servers
declare SERVER_DIR="/opt/craft/servers"
declare BIN_DIR="/opt/craft/bin"

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

# --- System Checks ---

# Check macOS version
MACOS_VERSION=$(sw_vers -productVersion)
REQUIRED_MACOS_VERSION="15.5"
if [[ "$(printf '%s\n' "$REQUIRED_MACOS_VERSION" "$MACOS_VERSION" | sort -V | head -n1)" != "$REQUIRED_MACOS_VERSION" ]]; then
	echo "Error: macOS version must be >= $REQUIRED_MACOS_VERSION. Current version: $MACOS_VERSION"
fi

# Check for sudo availability and privileges
if ! command -v sudo &>/dev/null; then
	abort "Error: 'sudo' command is not available. Please install sudo and ensure you have admin privileges."
fi

# --- Uninstall ---

if [ -z "$(ls -A "$SERVER_DIR")" ]; then
	echo "No servers found in $SERVER_DIR"
else
	while true; do

		if craft -v &>/dev/null; then
			echo "Stopping all servers"
			while IFS= read -r server; do
				servers+=("$server")
			done < <(craft -ls)

			for server in "${servers[@]}"; do
				sudo craft stop -n "$server" &>/dev/null
				sudo launchctl remove "craft.$server.daemon" &>/dev/null
				sudo rm -f "/Library/LaunchDaemons/craft.$server.daemon.plist" &>/dev/null
				launchctl list | grep -q "craft\.$server\.daemon" || [ -f "/Library/LaunchDaemons/craft.$server.daemon.plist" ] &&
					abort "Failed to stop $server. Please stop it manually using:\n\n  sudo craft stop -n \"$server\""
			done
		fi

		read -p "Delete all servers in $SERVER_DIR? (y/n) : " -n 1 -r
		echo
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			break
		elif [[ $REPLY =~ ^[Nn]$ ]]; then
			echo "Copying servers to ${HOME}/Craft"
			mkdir -p "${HOME}/Craft" &>/dev/null
			sudo cp -R "$SERVER_DIR"/* "${HOME}/Craft" &&
				[ -d "$HOME/Craft" ] &&
				[ -n "$(ls -A "$HOME/Craft")" ] ||
				abort "Failed to copy servers to ${HOME}/Craft"
			break
		else
			echo "Please enter y or n"
		fi

	done
fi

while true; do

	read -p "Are you sure you want to uninstall Craft? (y/n) : " -n 1 -r
	echo

	if [[ $REPLY =~ ^[Yy]$ ]]; then
		echo "Uninstalling Craft CLI"
		sudo rm -rf "/opt/craft" &&
			! [ -d "/opt/craft" ] ||
			abort "Failed to remove /opt/craft"
		break
	elif [[ $REPLY =~ ^[Nn]$ ]]; then
		echo "Cancelling uninstall"
		exit 0
	else
		echo "Please enter y or n"
	fi

done

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

if grep -q "export PATH.*$BIN_DIR" "$shell_profile"; then
	echo "Removing PATH from $shell_profile"
	# shellcheck disable=SC2016
	sed -i.bak '/export PATH="\$PATH:\/opt\/craft\/bin"/d' "$shell_profile" &>/dev/null
	rm -f "${shell_profile}.bak" &>/dev/null
	# shellcheck disable=SC2016
	grep -q "export PATH=\"\$PATH:$BIN_DIR\"" "$shell_profile" &>/dev/null && echo "Failed to remove PATH from $shell_profile. Please remove it manually."
fi

echo "Uninstall complete"
