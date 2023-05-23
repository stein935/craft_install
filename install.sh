#!/bin/bash

set -u

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]
then
  abort "Bash is required to interpret this script."
fi

# Check if script is run with force-interactive mode in CI
if [[ -n "${CI-}" && -n "${INTERACTIVE-}" ]]
then
  abort "Cannot run force-interactive mode in CI."
fi

# Check if both `INTERACTIVE` and `NONINTERACTIVE` are set
# Always use single-quoted strings with `exp` expressions
# shellcheck disable=SC2016
if [[ -n "${INTERACTIVE-}" && -n "${NONINTERACTIVE-}" ]]
then
  abort 'Both `$INTERACTIVE` and `$NONINTERACTIVE` are set. Please unset at least one variable and try again.'
fi

# Check if script is run in POSIX mode
if [[ -n "${POSIXLY_CORRECT+1}" ]]
then
  abort 'Bash must not run in POSIX mode. Please unset POSIXLY_CORRECT and try again.'
fi

# string formatters
if [[ -t 1 ]]
then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"
  do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")" >&2
}

# Check if script is run non-interactively (e.g. CI)
# If it is run non-interactively we should not prompt for passwords.
# Always use single-quoted strings with `exp` expressions
# shellcheck disable=SC2016
if [[ -z "${NONINTERACTIVE-}" ]]
then
  if [[ -n "${CI-}" ]]
  then
    warn 'Running in non-interactive mode because `$CI` is set.'
    NONINTERACTIVE=1
  elif [[ ! -t 0 ]]
  then
    if [[ -z "${INTERACTIVE-}" ]]
    then
      warn 'Running in non-interactive mode because `stdin` is not a TTY.'
      NONINTERACTIVE=1
    else
      warn 'Running in interactive mode despite `stdin` not being a TTY because `$INTERACTIVE` is set.'
    fi
  fi
else
  ohai 'Running in non-interactive mode because `$NONINTERACTIVE` is set.'
fi

# USER isn't always set so provide a fall back for the installer and subprocesses.
if [[ -z "${USER-}" ]]
then
  USER="$(chomp "$(id -un)")"
  export USER
fi

# First check OS.
OS="$(uname)"
if [[ "${OS}" == "Darwin" ]]
then
  CRAFT_ON_MACOS=1
else
  abort "Craft is only supported on macOS."
fi

if [[ -n "${CRAFT_ON_MACOS-}" ]]
then
  UNAME_MACHINE="$(/usr/bin/uname -m)"

  if [[ "${UNAME_MACHINE}" == "arm64" ]]
  then
    # On ARM macOS, this script installs to /opt/craft only
    CRAFT_PREFIX="/opt/craft"
    CRAFT_REPOSITORY="${CRAFT_PREFIX}"
  else
    # On Intel macOS, this script installs to /usr/local only
    CRAFT_PREFIX="/usr/local"
    CRAFT_REPOSITORY="${CRAFT_PREFIX}/craft"
  fi
  CRAFT_CACHE="${HOME}/Library/Caches/craft"

  STAT_PRINTF=("stat" "-f")
  PERMISSION_FORMAT="%A"
  CHOWN=("/usr/sbin/chown")
  CHGRP=("/usr/bin/chgrp")
  GROUP="admin"
  TOUCH=("/usr/bin/touch")
  INSTALL=("/usr/bin/install" -d -o "root" -g "wheel" -m "0755")
fi
CHMOD=("/bin/chmod")
MKDIR=("/bin/mkdir" "-p")
STEIN935_CRAFT_DEFAULT_GIT_REMOTE="https://github.com/stein935/craft"

# Use remote URLs of Craft repositories from environment if set.
STEIN935_CRAFT_GIT_REMOTE="${STEIN935_CRAFT_GIT_REMOTE:-"${STEIN935_CRAFT_DEFAULT_GIT_REMOTE}"}"
# The URLs with and without the '.git' suffix are the same Git remote. Do not prompt.
if [[ "${STEIN935_CRAFT_GIT_REMOTE}" == "${STEIN935_CRAFT_DEFAULT_GIT_REMOTE}.git" ]]
then
  STEIN935_CRAFT_GIT_REMOTE="${STEIN935_CRAFT_DEFAULT_GIT_REMOTE}"
fi
export STEIN935_CRAFT_GIT_REMOTE

# TODO: bump version when new macOS is released or announced
MACOS_NEWEST_UNSUPPORTED="14.0"
# TODO: bump version when new macOS is released
MACOS_OLDEST_SUPPORTED="11.0"

REQUIRED_GIT_VERSION=2.7.0   # CRAFT_MINIMUM_GIT_VERSION in craft.sh in craft/craft
REQUIRED_JAVA_VERSION=17.0.0

unset HAVE_SUDO_ACCESS # unset this from the environment

have_sudo_access() {
  if [[ ! -x "/usr/bin/sudo" ]]
  then
    return 1
  fi

  local -a SUDO=("/usr/bin/sudo")
  if [[ -n "${SUDO_ASKPASS-}" ]]
  then
    SUDO+=("-A")
  elif [[ -n "${NONINTERACTIVE-}" ]]
  then
    SUDO+=("-n")
  fi

  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]
  then
    if [[ -n "${NONINTERACTIVE-}" ]]
    then
      "${SUDO[@]}" -l mkdir &>/dev/null
    else
      "${SUDO[@]}" -v && "${SUDO[@]}" -l mkdir &>/dev/null
    fi
    HAVE_SUDO_ACCESS="$?"
  fi

  if [[ -n "${CRAFT_ON_MACOS-}" ]] && [[ "${HAVE_SUDO_ACCESS}" -ne 0 ]]
  then
    abort "Need sudo access on macOS (e.g. the user ${USER} needs to be an Administrator)!"
  fi

  return "${HAVE_SUDO_ACCESS}"
}

execute() {
  if ! "$@"
  then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if have_sudo_access
  then
    if [[ -n "${SUDO_ASKPASS-}" ]]
    then
      args=("-A" "${args[@]}")
    fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

getc() {
  local save_state
  save_state="$(/bin/stty -g)"
  /bin/stty raw -echo
  IFS='' read -r -n 1 -d '' "$@"
  /bin/stty "${save_state}"
}

ring_bell() {
  # Use the shell's audible bell.
  if [[ -t 1 ]]
  then
    printf "\a"
  fi
}

wait_for_user() {
  local c
  echo
  echo "Press ${tty_bold}RETURN${tty_reset}/${tty_bold}ENTER${tty_reset} to continue or any other key to abort:"
  getc c
  # we test for \r and \n because some stuff does \r instead
  if ! [[ "${c}" == $'\r' || "${c}" == $'\n' ]]
  then
    exit 1
  fi
}

major_minor() {
  echo "${1%%.*}.$(
    x="${1#*.}"
    echo "${x%%.*}"
  )"
}

version_gt() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -gt "${2#*.}" ]]
}
version_ge() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -ge "${2#*.}" ]]
}
version_lt() {
  [[ "${1%.*}" -lt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -lt "${2#*.}" ]]
}

check_run_command_as_root() {
  [[ "${EUID:-${UID}}" == "0" ]] || return

  # Allow Azure Pipelines/GitHub Actions/Docker/Concourse/Kubernetes to do everything as root (as it's normal there)
  [[ -f /.dockerenv ]] && return
  [[ -f /run/.containerenv ]] && return
  [[ -f /proc/1/cgroup ]] && grep -E "azpl_job|actions_job|docker|garden|kubepods" -q /proc/1/cgroup && return

  abort "Don't run this as root!"
}

should_install_command_line_tools() {
  if version_gt "${macos_version}" "10.13"
  then
    ! [[ -e "/Library/Developer/CommandLineTools/usr/bin/git" ]]
  else
    ! [[ -e "/Library/Developer/CommandLineTools/usr/bin/git" ]] ||
      ! [[ -e "/usr/include/iconv.h" ]]
  fi
}

get_permission() {
  "${STAT_PRINTF[@]}" "${PERMISSION_FORMAT}" "$1"
}

user_only_chmod() {
  [[ -d "$1" ]] && [[ "$(get_permission "$1")" != 75[0145] ]]
}

exists_but_not_writable() {
  [[ -e "$1" ]] && ! [[ -r "$1" && -w "$1" && -x "$1" ]]
}

get_owner() {
  "${STAT_PRINTF[@]}" "%u" "$1"
}

file_not_owned() {
  [[ "$(get_owner "$1")" != "$(id -u)" ]]
}

get_group() {
  "${STAT_PRINTF[@]}" "%g" "$1"
}

file_not_grpowned() {
  [[ " $(id -G "${USER}") " != *" $(get_group "$1") "* ]]
}

test_git() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi

  local git_version_output
  git_version_output="$("$1" --version 2>/dev/null)"
  if [[ "${git_version_output}" =~ "git version "([^ ]*).* ]]
  then
    version_ge "$(major_minor "${BASH_REMATCH[1]}")" "$(major_minor "${REQUIRED_GIT_VERSION}")"
  else
    abort "Unexpected Git version: '${git_version_output}'!"
  fi
}

test_java() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi

  local java_version_output
  java_version_output="$("$1" --version 2>/dev/null)"
  if [[ "${java_version_output}" =~ "java "([^ ]*).* ]]
  then
    version_ge "$(major_minor "${BASH_REMATCH[1]}")" "$(major_minor "${REQUIRED_JAVA_VERSION}")"
  else
    abort "Unexpected Java version: '${java_version_output}'!"
  fi
}

# Search for the given executable in PATH (avoids a dependency on the `which` command)
which() {
  # Alias to Bash built-in command `type -P`
  type -P "$@"
}

# Search PATH for the specified program that satisfies Craft requirements
# function which is set above
# shellcheck disable=SC2230
find_tool() {
  if [[ $# -ne 1 ]]
  then
    return 1
  fi

  local executable
  while read -r executable
  do
    if [[ "${executable}" != /* ]]
    then
      warn "Ignoring ${executable} (relative paths don't work)"
    elif "test_$1" "${executable}"
    then
      echo "${executable}"
      break
    fi
  done < <(which -a "$1")
}

# Invalidate sudo timestamp before exiting (if it wasn't active before).
if [[ -x /usr/bin/sudo ]] && ! /usr/bin/sudo -n -v 2>/dev/null
then
  trap '/usr/bin/sudo -k' EXIT
fi

# Things can fail later if `pwd` doesn't exist.
# Also sudo prints a warning message for no good reason
cd "/usr" || exit 1

####################################################################### script

# shellcheck disable=SC2016
ohai 'Checking for `sudo` access (which may request your password)...'

if [[ -n "${CRAFT_ON_MACOS-}" ]]
then
  have_sudo_access
elif ! [[ -w "${CRAFT_PREFIX}" ]] &&
     ! [[ -w "/home/linuxbrew" ]] &&
     ! [[ -w "/home" ]] &&
     ! have_sudo_access
then
  abort "$(
    cat <<EOABORT
Insufficient permissions to install Craft to \"${CRAFT_PREFIX}\" (the default prefix).
EOABORT
  )"
fi

check_run_command_as_root

if [[ -d "${CRAFT_PREFIX}" && ! -x "${CRAFT_PREFIX}" ]]
then
  abort "$(
    cat <<EOABORT
The Craft prefix ${tty_underline}${CRAFT_PREFIX}${tty_reset} exists but is not searchable.
If this is not intentional, please restore the default permissions and
try running the installer again:
    sudo chmod 775 ${CRAFT_PREFIX}
EOABORT
  )"
fi

if [[ -n "${CRAFT_ON_MACOS-}" ]]
then
  # On macOS, support 64-bit Intel and ARM
  if [[ "${UNAME_MACHINE}" != "arm64" ]] && [[ "${UNAME_MACHINE}" != "x86_64" ]]
  then
    abort "Craft is only supported on Intel and ARM processors!"
  fi
fi

if [[ -n "${CRAFT_ON_MACOS-}" ]]
then
  macos_version="$(major_minor "$(/usr/bin/sw_vers -productVersion)")"
  if version_lt "${macos_version}" "10.7"
  then
    abort "$(
      cat <<EOABORT
Your Mac OS X version is too old.
EOABORT
    )"
  elif version_lt "${macos_version}" "10.11"
  then
    abort "Your OS X version is too old."
  elif version_ge "${macos_version}" "${MACOS_NEWEST_UNSUPPORTED}" ||
       version_lt "${macos_version}" "${MACOS_OLDEST_SUPPORTED}"
  then
    who="We"
    what=""
    if version_ge "${macos_version}" "${MACOS_NEWEST_UNSUPPORTED}"
    then
      what="pre-release version"
    else
      who+=" (and Apple)"
      what="old version"
    fi
    ohai "You are using macOS ${macos_version}."
    ohai "${who} do not provide support for this ${what}."

    echo "$(
      cat <<EOS
This installation may not succeed.
After installation, you will encounter build failures with some formulae.
You are responsible for resolving any issues you experience while you are running this ${what}.
EOS
    )
" | tr -d "\\"
  fi
fi

ohai "This script will install:"
echo "${CRAFT_PREFIX}/bin/craft"
echo "${CRAFT_REPOSITORY}"
echo "${HOME}/Craft"

directories=(
  bin 
  bin/craft
)
servers_dirs=(
  ${HOME}
  ${HOME}/Craft
)
group_chmods=()
for dir in "${directories[@]}"
do
  if exists_but_not_writable "${CRAFT_PREFIX}/${dir}"
  then
    group_chmods+=("${CRAFT_PREFIX}/${dir}")
  fi
done
for dir in "${servers_dirs[@]}"
do
  if exists_but_not_writable "${dir}"
  then
    group_chmods+=("${dir}")
  fi
done

directories=(
  bin 
)
servers_dirs=(
  ${HOME}/Craft
)
mkdirs=()
for dir in "${directories[@]}"
do
  if ! [[ -d "${CRAFT_PREFIX}/${dir}" ]]
  then
    mkdirs+=("${CRAFT_PREFIX}/${dir}")
  fi
done
for dir in "${servers_dirs[@]}"
do
  if ! [[ -d "${dir}" ]]
  then
    mkdirs+=("${dir}")
  fi
done

chmods=()
if [[ "${#group_chmods[@]}" -gt 0 ]]
then
  chmods+=("${group_chmods[@]}")
fi

chowns=()
chgrps=()
if [[ "${#chmods[@]}" -gt 0 ]]
then
  for dir in "${chmods[@]}"
  do
    if file_not_owned "${dir}"
    then
      chowns+=("${dir}")
    fi
    if file_not_grpowned "${dir}"
    then
      chgrps+=("${dir}")
    fi
  done
fi

if [[ "${#group_chmods[@]}" -gt 0 ]]
then
  ohai "The following existing directories will be made group writable:"
  printf "%s\n" "${group_chmods[@]}"
fi
if [[ "${#chowns[@]}" -gt 0 ]]
then
  ohai "The following existing directories will have their owner set to ${tty_underline}${USER}${tty_reset}:"
  printf "%s\n" "${chowns[@]}"
fi
if [[ "${#chgrps[@]}" -gt 0 ]]
then
  ohai "The following existing directories will have their group set to ${tty_underline}${GROUP}${tty_reset}:"
  printf "%s\n" "${chgrps[@]}"
fi
if [[ "${#mkdirs[@]}" -gt 0 ]]
then
  ohai "The following new directories will be created:"
  printf "%s\n" "${mkdirs[@]}"
fi

if should_install_command_line_tools
then
  ohai "The Xcode Command Line Tools will be installed."
fi

non_default_repos=""
additional_shellenv_commands=()
if [[ "${STEIN935_CRAFT_DEFAULT_GIT_REMOTE}" != "${STEIN935_CRAFT_GIT_REMOTE}" ]]
then
  ohai "STEIN935_CRAFT_GIT_REMOTE is set to a non-default URL:"
  echo "${tty_underline}${STEIN935_CRAFT_GIT_REMOTE}${tty_reset} will be used as the craft Git remote."
  non_default_repos="stein935/craft"
  additional_shellenv_commands+=("export STEIN935_CRAFT_GIT_REMOTE=\"${STEIN935_CRAFT_GIT_REMOTE}\"")
fi

if [[ -z "${NONINTERACTIVE-}" ]]
then
  ring_bell
  wait_for_user
fi

if [[ -d "${CRAFT_PREFIX}" ]]
then
  if [[ "${#chmods[@]}" -gt 0 ]]
  then
    execute_sudo "${CHMOD[@]}" "u+rwx" "${chmods[@]}"
  fi
  if [[ "${#group_chmods[@]}" -gt 0 ]]
  then
    execute_sudo "${CHMOD[@]}" "g+rwx" "${group_chmods[@]}"
  fi
  if [[ "${#chowns[@]}" -gt 0 ]]
  then
    execute_sudo "${CHOWN[@]}" "${USER}" "${chowns[@]}"
  fi
  if [[ "${#chgrps[@]}" -gt 0 ]]
  then
    execute_sudo "${CHGRP[@]}" "${GROUP}" "${chgrps[@]}"
  fi
else
  execute_sudo "${INSTALL[@]}" "${CRAFT_PREFIX}"
fi

if [[ "${#mkdirs[@]}" -gt 0 ]]
then
  execute_sudo "${MKDIR[@]}" "${mkdirs[@]}"
  execute_sudo "${CHMOD[@]}" "ug=rwx" "${mkdirs[@]}"
  execute_sudo "${CHOWN[@]}" "${USER}" "${mkdirs[@]}"
  execute_sudo "${CHGRP[@]}" "${GROUP}" "${mkdirs[@]}"
fi

if ! [[ -d "${CRAFT_REPOSITORY}" ]]
then
  execute_sudo "${MKDIR[@]}" "${CRAFT_REPOSITORY}"
fi
execute_sudo "${CHOWN[@]}" "-R" "${USER}:${GROUP}" "${CRAFT_REPOSITORY}"

if ! [[ -d "${CRAFT_CACHE}" ]]
then
  if [[ -n "${CRAFT_ON_MACOS-}" ]]
  then
    execute_sudo "${MKDIR[@]}" "${CRAFT_CACHE}"
  else
    execute "${MKDIR[@]}" "${CRAFT_CACHE}"
  fi
fi
if exists_but_not_writable "${CRAFT_CACHE}"
then
  execute_sudo "${CHMOD[@]}" "g+rwx" "${CRAFT_CACHE}"
fi
if file_not_owned "${CRAFT_CACHE}"
then
  execute_sudo "${CHOWN[@]}" "-R" "${USER}" "${CRAFT_CACHE}"
fi
if file_not_grpowned "${CRAFT_CACHE}"
then
  execute_sudo "${CHGRP[@]}" "-R" "${GROUP}" "${CRAFT_CACHE}"
fi
if [[ -d "${CRAFT_CACHE}" ]]
then
  execute "${TOUCH[@]}" "${CRAFT_CACHE}/.cleaned"
fi

if should_install_command_line_tools && version_ge "${macos_version}" "10.13"
then
  ohai "Searching online for the Command Line Tools"
  # This temporary file prompts the 'softwareupdate' utility to list the Command Line Tools
  clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  execute_sudo "${TOUCH[@]}" "${clt_placeholder}"

  clt_label_command="/usr/sbin/softwareupdate -l |
                      grep -B 1 -E 'Command Line Tools' |
                      awk -F'*' '/^ *\\*/ {print \$2}' |
                      sed -e 's/^ *Label: //' -e 's/^ *//' |
                      sort -V |
                      tail -n1"
  clt_label="$(chomp "$(/bin/bash -c "${clt_label_command}")")"

  if [[ -n "${clt_label}" ]]
  then
    ohai "Installing ${clt_label}"
    execute_sudo "/usr/sbin/softwareupdate" "-i" "${clt_label}"
    execute_sudo "/usr/bin/xcode-select" "--switch" "/Library/Developer/CommandLineTools"
  fi
  execute_sudo "/bin/rm" "-f" "${clt_placeholder}"
fi

# Headless install may have failed, so fallback to original 'xcode-select' method
if should_install_command_line_tools && test -t 0
then
  ohai "Installing the Command Line Tools (expect a GUI popup):"
  execute "/usr/bin/xcode-select" "--install"
  echo "Press any key when the installation has completed."
  getc
  execute_sudo "/usr/bin/xcode-select" "--switch" "/Library/Developer/CommandLineTools"
fi

if [[ -n "${CRAFT_ON_MACOS-}" ]] && ! output="$(/usr/bin/xcrun clang 2>&1)" && [[ "${output}" == *"license"* ]]
then
  abort "$(
    cat <<EOABORT
You have not agreed to the Xcode license.
Before running the installer again please agree to the license by opening
Xcode.app or running:
    sudo xcodebuild -license
EOABORT
  )"
fi

USABLE_GIT="$(find_tool git)"
if [[ -z "${USABLE_GIT}" ]]
then
  abort "$(
    cat <<EOABORT
You must install Git before installing Craft. See:
EOABORT
  )"
fi

USABLE_JAVA="$(find_tool java)"
if [[ -z "${USABLE_JAVA}" ]]
then
  abort "$(
    cat <<EOABORT
You must install Java 17+ before installing Craft. See:
EOABORT
  )"
fi


ohai "Downloading and installing Craft..."
(
  cd "${CRAFT_REPOSITORY}" >/dev/null || return

  # we do it in four steps to avoid merge errors when reinstalling
  execute "${USABLE_GIT}" "-c" "init.defaultBranch=main" "init" "--quiet"

  # "git remote add" will fail if the remote is defined in the global config
  execute "${USABLE_GIT}" "config" "remote.origin.url" "${STEIN935_CRAFT_GIT_REMOTE}"
  execute "${USABLE_GIT}" "config" "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"

  # ensure we don't munge line endings on checkout
  execute "${USABLE_GIT}" "config" "--bool" "core.autocrlf" "false"

  # make sure symlinks are saved as-is
  execute "${USABLE_GIT}" "config" "--bool" "core.symlinks" "true"

  execute "${USABLE_GIT}" "fetch" "--force" "origin"
  execute "${USABLE_GIT}" "fetch" "--force" "--tags" "origin"

  execute "${USABLE_GIT}" "reset" "--hard" "origin/main"

  if [[ "${CRAFT_REPOSITORY}" != "${CRAFT_PREFIX}" ]]
  then
    if [[ "${CRAFT_REPOSITORY}" == "${CRAFT_PREFIX}/craft" ]]
    then
      execute "ln" "-sf" "../craft/craft" "${CRAFT_PREFIX}/bin/craft"
    else
      abort "The Craft repository should be placed in the Craft prefix directory."
    fi
  fi


  # execute "${CRAFT_PREFIX}/bin/craft" "update" "--force" "--quiet"
) || exit 1

if [[ ":${PATH}:" != *":${CRAFT_PREFIX}/bin:"* ]]
then
  warn "${CRAFT_PREFIX}/bin is not in your PATH.
  Instructions on how to configure your shell for Craft
  can be found in the 'Next steps' section below."
fi

ohai "Installation successful!"
echo

ring_bell

ohai "Next steps:"
case "${SHELL}" in
  */bash*)
    if [[ -r "${HOME}/.bash_profile" ]]
    then
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

if grep -qs "eval \"\$(${CRAFT_PREFIX}/bin/craft shellenv)\"" "${shell_profile}"
then
  if ! [[ -x "$(command -v craft)" ]]
  then
    cat <<EOS
- Run this command in your terminal to add Craft to your ${tty_bold}PATH${tty_reset}:
    eval "\$(${CRAFT_PREFIX}/bin/craft shellenv)"
EOS
  fi
else
  cat <<EOS
- Run these two commands in your terminal to add Craft to your ${tty_bold}PATH${tty_reset}:
    (echo; echo 'eval "\$(${CRAFT_PREFIX}/bin/craft shellenv)"') >> ${shell_profile}
    eval "\$(${CRAFT_PREFIX}/bin/craft shellenv)"
EOS
fi

if [[ -n "${non_default_repos}" ]]
then
  plural=""
  if [[ "${#additional_shellenv_commands[@]}" -gt 1 ]]
  then
    plural="s"
  fi
  printf -- "- Run these commands in your terminal to add the non-default Git remote%s for %s:\n" "${plural}" "${non_default_repos}"
  printf "    echo '# Set PATH, MANPATH, etc., for Craft.' >> %s\n" "${shell_profile}"
  printf "    echo '%s' >> ${shell_profile}\n" "${additional_shellenv_commands[@]}"
  printf "    %s\n" "${additional_shellenv_commands[@]}"
fi

cat <<EOS
- Run ${tty_bold}craft help${tty_reset} to get started

EOS