#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
  echo "$0 is not running as root. Try using sudo."
  exit 2
fi

_debug() {
  [ -z "$DEBUG" ] || {
    >&2 echo "DEBUG: $@"
  }
}

clean () {
  [ -f ~/.$1 ] || return
  mv ~/.$1 ~/.$1.sav
}

check_apps () {
  for x in "${!_pkgs[@]}"; do
    if type "$x" > /dev/null 2>&1; then
      _debug "pkg -> found $x"
    else
      _install+=("$x")
      _debug "pkg -> missing $x"
    fi
  done
}

apt_update () {
  echo "-------------------------------------"
  echo "   Starting system update process"
  echo "-------------------------------------"
  echo

  # Update package list
  echo "Updating package list..."
  apt update || return 1

  if [ "$_distro" == "ubuntu" ]; then
    apt install software-properties-common -y || return 1
    add-apt-repository ppa:zhangsongcui3371/fastfetch -y || return 1
    apt update || return 1
  fi

  # Upgrade all packages automatically
  echo
  echo "Upgrading packages..."
  apt upgrade -y || return 1

  # (Optional) clean up
  echo
  echo "Cleaning up unnecessary packages..."
  apt autoremove -y || return 1
  apt autoclean -y || return 1

  echo
  echo "-------------------------------------"
  echo "   System update complete!"
  echo "-------------------------------------"
}

dnf_update () {
  echo "-------------------------------------"
  echo "   Starting system update process"
  echo "-------------------------------------"
  echo

  echo "Upgrading packages..."
  dnf upgrade -y || return 1

  echo
  echo "Cleaning up unnecessary packages..."
  dnf autoremove -y || return 1
  dnf clean all || return 1

  echo
  echo "-------------------------------------"
  echo "   System update complete!"
  echo "-------------------------------------"
}

enable_epel () {
  echo "Enabling the EPEL repository..."
  dnf install -y epel-release || return 1
}

install_apps () {
  echo "-------------------------------------"
  echo "   Installing applications"
  echo "-------------------------------------"
  echo
  
  local -a _installstring=()
  for x in "${_install[@]}"; do
    _installstring+=("${_pkgs[$x]}")
  done
  _debug "_installstring -> ${_installstring[*]}"

  if [ "${#_installstring[@]}" -gt 0 ]; then
    case "$_distro" in
      debian|ubuntu|raspbian) apt install -y "${_installstring[@]}" || return 1 ;;
      rocky) dnf install -y "${_installstring[@]}" || return 1 ;;
    esac
  fi

  echo "Cleaning up unnecessary packages..."
  case "$_distro" in
    debian|ubuntu|raspbian)
      apt autoremove -y || return 1
      apt autoclean -y || return 1
      ;;
    rocky)
      dnf autoremove -y || return 1
      dnf clean all || return 1
      ;;
  esac

  echo
  echo "-------------------------------------"
  echo "   Applications installed!"
  echo "-------------------------------------"
}

install_mc_client () {
  local _mc_arch _mc_tmp _mc_dest
  case "$(uname -m)" in
    x86_64) _mc_arch="amd64" ;;
    aarch64) _mc_arch="arm64" ;;
    armv6l|armv7l)
      echo "Skipping the MinIO mc client: Linux ARM 32-bit builds are unavailable."
      return 0
      ;;
    *)
      echo "Unsupported architecture for the MinIO mc client: $(uname -m)" >&2
      return 1
      ;;
  esac

  _mc_tmp=$(mktemp) || return 1
  echo "Downloading MinIO mc client for Linux ${_mc_arch}..."
  if ! curl --fail --progress-bar --location \
    "https://dl.min.io/aistor/mc/release/linux-${_mc_arch}/mc" \
    --output "$_mc_tmp"; then
    rm -f "$_mc_tmp"
    echo "Failed to download the MinIO mc client." >&2
    return 1
  fi

  if [ "$_truenas" = true ]; then
    _mc_dest="${_homedir}/.bin"
    if ! mkdir -p "$_mc_dest" || ! install -m 0755 "$_mc_tmp" "${_mc_dest}/mc"; then
      rm -f "$_mc_tmp"
      echo "Failed to install the MinIO mc client in ${_mc_dest}." >&2
      return 1
    fi
  elif ! chmod +x "$_mc_tmp" || ! install -m 0755 "$_mc_tmp" /usr/local/bin/mc; then
    rm -f "$_mc_tmp"
    echo "Failed to install the MinIO mc client." >&2
    return 1
  fi
  rm -f "$_mc_tmp"

  if [ "$_truenas" = true ]; then
    "${_mc_dest}/mc" --version || return 1
  else
    mc --version || return 1
  fi
}

install_czkawka_cli () {
  local _czkawka_tmp _czkawka_dest _czkawka_arch
  if [ "$_os" != linux ]; then
    _debug "Skipping Czkawka CLI: supported only on Linux"
    return 0
  fi
  case "$(uname -m)" in
    x86_64) _czkawka_arch="x86_64" ;;
    aarch64|arm64) _czkawka_arch="arm64" ;;
    *)
      _debug "Skipping Czkawka CLI: unsupported architecture $(uname -m)"
      return 0
      ;;
  esac

  if [ "$_truenas" = true ]; then
    _czkawka_dest="${_homedir}/.bin"
  else
    _czkawka_dest="/usr/local/bin"
  fi

  _czkawka_tmp=$(mktemp) || return 1
  echo "Downloading Czkawka CLI for Linux ${_czkawka_arch}..."
  if ! curl --fail --progress-bar --location \
    "https://github.com/qarmin/czkawka/releases/download/12.0.2/linux_czkawka_cli_${_czkawka_arch}" \
    --output "$_czkawka_tmp"; then
    rm -f "$_czkawka_tmp"
    echo "Failed to download the Czkawka CLI." >&2
    return 1
  fi

  if ! mkdir -p "$_czkawka_dest" || ! install -m 0755 "$_czkawka_tmp" "${_czkawka_dest}/czkawka"; then
    rm -f "$_czkawka_tmp"
    echo "Failed to install the Czkawka CLI in ${_czkawka_dest}." >&2
    return 1
  fi
  rm -f "$_czkawka_tmp"
}

set_user_bin_ownership () {
  local _bindir _binary
  [ "$_truenas" = true ] || return 0
  [ -d "${_homedir}/.bin" ] || return 0

  _bindir="${_homedir}/.bin"
  chown "${_username}:${_usergroup}" "$_bindir" || return 1
  for _binary in "${_bindir}/mc" "${_bindir}/czkawka"; do
    [ -e "$_binary" ] || continue
    chown -h "${_username}:${_usergroup}" "$_binary" || return 1
  done
}

create_userdir () {
  mkdir -p "$1" || return 1
  chown -R "${_username}:${_usergroup}" "$1" || return 1
  chown "${_username}:${_usergroup}" "$1" || return 1
}

create_rootdir () {
  mkdir -p "$1" || return 1
  chown -R root:root "$1" || return 1
  chown root:root "$1" || return 1
}

create_userlink () {
  ln -sf "$1" "$2"
  chown -h "${_username}:${_usergroup}" "$2"
}

create_rootlink () {
  ln -sf $1 $2
}

#######################################################################
# Main Routine
#######################################################################
_install=()
declare -A _debian_pkgs=(
  [ping]="iputils-ping"
  [tmux]="tmux"
  [git]="git"
  [7z]="p7zip-full"
  [zip]="zip"
  [screen]="screen"
  [fastfetch]="fastfetch"
  [htop]="htop"
  [bashtop]="bashtop"
  [btop]="btop"
  [ifconfig]="net-tools"
  [dig]="dnsutils"
  [sg_inq]="sg3-utils"
  [minicom]="minicom"
  [less]="less"
  [wget]="wget"
  [curl]="curl"
  [rsync]="rsync"
  [vim]="vim"
)
declare -A _ubuntu_pkgs=(
  [ping]="iputils-ping"
  [tmux]="tmux"
  [git]="git"
  [7z]="p7zip-full"
  [zip]="zip"
  [screen]="screen"
  [fastfetch]="fastfetch"
  [htop]="htop"
  [bashtop]="bashtop"
  [btop]="btop"
  [ifconfig]="net-tools"
  [dig]="dnsutils"
  [sg_inq]="sg3-utils"
  [minicom]="minicom"
  [less]="less"
  [wget]="wget"
  [curl]="curl"
  [rsync]="rsync"
  [vim]="vim"
)
declare -A _rocky_pkgs=(
  [ping]="iputils"
  [tmux]="tmux"
  [git]="git"
  [7z]="p7zip"
  [zip]="zip"
  [screen]="screen"
  [fastfetch]="fastfetch"
  [htop]="htop"
  [btop]="btop"
  [ifconfig]="net-tools"
  [dig]="bind-utils"
  [sg_inq]="sg3_utils"
  [minicom]="minicom"
  [less]="less"
  [wget]="wget"
  [curl]="curl"
  [rsync]="rsync"
  [vim]="vim-enhanced"
)

_scriptpath="$(dirname "$(readlink -f "$0")")"
_debug "_scriptpath -> $_scriptpath"

_username=$(logname)
_usergroup=$(id -gn "$_username")
_homedir=$(getent passwd "$_username" | awk -F: '{print $6}')
_debug "_homedir -> $_homedir"

_rootdir=$(getent passwd root | awk -F: '{print $6}')
_debug "_rootdir -> $_rootdir"

_uname=$(uname -a)
_os=$(uname | tr '[:upper:]' '[:lower:]')
_truenas=false
if [[ "${_uname,,}" == *truenas* ]]; then
  _truenas=true
fi
_debug "_os -> $_os"
_debug "_truenas -> $_truenas"

echo "Running as user '${_username}' with group '${_usergroup}'."

if [ "$_truenas" = true ]; then
  _debug "TrueNAS detected; skipping package installation and updates"
  _os_summary="TrueNAS (${_uname})"
elif [ -r /etc/os-release ]; then
  . /etc/os-release
  _distro="${ID,,}"
  _os_summary="${PRETTY_NAME:-$_distro} (${_distro})"
else
  echo "Unable to determine Linux distribution: /etc/os-release is unavailable." >&2
  exit 1
fi
_debug "_distro -> $_distro"

if [ "$_truenas" != true ]; then
  case "$_distro" in
    debian|ubuntu|raspbian|rocky) ;;
    *)
      echo "Unsupported Linux distribution: $_distro" >&2
      exit 1
      ;;
  esac
  _pkg_distro="$_distro"
  if [ "$_pkg_distro" = "raspbian" ]; then
    _pkg_distro="debian"
  fi
  declare -n _pkgs="_${_pkg_distro}_pkgs"
fi

echo "Detected operating system: ${_os_summary}"
read -r -p "Is this correct? Continue? [y/N] " _confirm_os
case "${_confirm_os,,}" in
  y|yes) ;;
  *)
    echo "Installation cancelled."
    exit 0
    ;;
esac

if [ "$_truenas" != true ] && [ "$_distro" = rocky ]; then
  enable_epel || exit 1
fi

clean bashrc
clean bash_profile
clean bash_logout

if [ "$_truenas" != true ]; then
  case "$_distro" in
    debian|ubuntu|raspbian) apt_update || exit 1 ;;
    rocky) dnf_update || exit 1 ;;
  esac
  check_apps

  if [ ${#_install[@]} -gt 0 ]; then
    install_apps || exit 1
  fi
fi
install_mc_client || exit 1
install_czkawka_cli || exit 1
set_user_bin_ownership || exit 1

echo "------------------------------------------"
echo "   Applying user profile customizations"
echo "------------------------------------------"
echo

cd "$_homedir"
create_userdir "${_homedir}/.config/fastfetch"
create_userdir "${_homedir}/.vim/colors"
create_userdir "${_homedir}/.ssh"
if [ "$_truenas" != true ]; then
  chmod 700 "${_homedir}/.ssh"
fi
create_userlink "../linux-profile/conf/authorized_keys" ".ssh/authorized_keys"
create_userlink "linux-profile/conf/bashrc" ".bashrc"
create_userlink "linux-profile/conf/bash_aliases" ".bash_aliases"
create_userlink "../../linux-profile/conf/fastfetch.jsonc" ".config/fastfetch/config.jsonc"
create_userlink "linux-profile/conf/vimrc" ".vimrc"

echo "------------------------------------------"
echo "   Applying root profile customizations"
echo "------------------------------------------"
echo

cp -r linux-profile/ /root

cd "/root"
create_rootdir "/root/.config/fastfetch"
create_rootdir "/root/.vim/colors"

create_rootlink "linux-profile/conf/bashrc" ".bashrc"
create_rootlink "linux-profile/conf/bash_aliases" ".bash_aliases"
create_rootlink "../../linux-profile/conf/fastfetch.jsonc" ".config/fastfetch/config.jsonc"
create_rootlink "linux-profile/conf/vimrc" ".vimrc"
