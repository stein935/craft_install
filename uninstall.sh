#!/bin/bash

uninstall=false
delete_servers=false
servers=()

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

ohai 'Checking for `sudo` access (which may request your password)...'

have_sudo_access

while true; do

  warn "Uninstall Craft CLI?"
  read -p "(y/n) : " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then

    uninstall=true

    break

  elif [[ $REPLY =~ ^[Nn]$ ]]; then

    warn "Cancelling uninstall" 

    exit 0

  else

    echo "Please enter y or n"

  fi

done

while true; do

  warn "Delete all servers in ${HOME}/Craft?"
  read -p "(y/n) : " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then

    delete_servers=true

    break

  elif [[ $REPLY =~ ^[Nn]$ ]]; then

    warn "Leaving servers alone" 

    break

  else

    echo "Please enter y or n"

  fi

done

if [ "$uninstall" == true ]; then 
  ohai "Stopping all servers"
  servers=$(craft -ls)
  for server in $servers
  do
    craft stop -n $server &>/dev/null
  done
  ohai "Deleting Craft CLI files"
  execute_sudo "rm" "-r" "/usr/local/craft"
  execute_sudo "rm" "-r" "/usr/local/bin/craft"
fi

if [ "$delete_servers" == true ]; then

  while true; do

    warn "Permanently delete all Minecraft servers and worlds in ${HOME}/Craft?"
    read -p "(y/n) : " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then

      execute_sudo "rm" "-r" "$HOME/Craft"

      for server in $servers
      do
        echo "Deleted: $server"
      done

      break

    elif [[ $REPLY =~ ^[Nn]$ ]]; then

      warn "Leaving servers alone" 

      break

    else

      echo "Please enter y or n"

    fi

  done

fi

ohai "Done!"