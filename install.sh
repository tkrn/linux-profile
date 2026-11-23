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

_green() { printf '\033[32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

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
  local _source_file
  echo
  echo "-------------------------------------"
  echo "   Starting system update process"
  echo "-------------------------------------"
  echo

  for _source_file in /etc/apt/sources.list.d/*zhangsongcui* /etc/apt/sources.list.d/deb.griffo.io.list; do
    [ -f "$_source_file" ] || continue
    echo "Removing external Fastfetch repository source: $_source_file"
    rm -f "$_source_file" || return 1
  done

  # Update package list
  echo "Updating package list..."
  apt update || return 1

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
  echo
}

dnf_update () {
  echo
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
  echo

}

install_fastfetch_manual () {
  local _fastfetch_url _fastfetch_ext _fastfetch_tmp
  case "$_distro" in
    debian|ubuntu)
      _fastfetch_ext="deb"
      _fastfetch_url="https://github.com/fastfetch-cli/fastfetch/releases/download/2.71.0/fastfetch-linux-amd64.deb"
      ;;
    rocky)
      _fastfetch_ext="rpm"
      _fastfetch_url="https://github.com/fastfetch-cli/fastfetch/releases/download/2.71.0/fastfetch-linux-amd64.rpm"
      ;;
    *) return 0 ;;
  esac

  if [ "$(uname -m)" != x86_64 ]; then
    echo "Skipping Fastfetch 2.71.0: the supplied package is for x86_64 only."
    return 0
  fi

  _fastfetch_tmp=$(mktemp --suffix=".${_fastfetch_ext}") || return 1
  echo "Downloading Fastfetch 2.71.0 for ${_distro}..."
  if ! curl --fail --progress-bar --location "$_fastfetch_url" --output "$_fastfetch_tmp"; then
    rm -f "$_fastfetch_tmp"
    echo "Failed to download Fastfetch 2.71.0." >&2
    return 1
  fi

  case "$_fastfetch_ext" in
    deb) apt install -y "$_fastfetch_tmp" ;;
    rpm) dnf install -y "$_fastfetch_tmp" ;;
  esac
  local _install_status=$?
  rm -f "$_fastfetch_tmp"
  return "$_install_status"
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
  local _owner _group _mode _expected_mode=775 _created=false
  if [ "$1" = "${_homedir}/.ssh" ]; then
    _expected_mode=700
  fi
  if [ -d "$1" ]; then
    echo "User directory already exists: $1"
  else
    echo "Creating user directory: $1"
    if ! mkdir -p "$1"; then
      _red "Failed to create user directory: $1"
      return 1
    fi
    _created=true
  fi

  if ! read -r _owner _group _mode < <(stat -c '%U %G %a' "$1"); then
    _red "Failed to inspect user directory: $1"
    return 1
  fi
  if [ "$_owner" != "$_username" ] || [ "$_group" != "$_usergroup" ]; then
    _yellow "Correcting ownership of $1 from ${_owner}:${_group} to ${_username}:${_usergroup}"
    if ! chown -R "${_username}:${_usergroup}" "$1" || ! chown "${_username}:${_usergroup}" "$1"; then
      _red "Failed to set ownership on user directory: $1"
      return 1
    fi
  else
    echo "Ownership is correct for $1: ${_owner}:${_group}"
  fi
  if { [ "$_truenas" != true ] || [ "$_expected_mode" = 700 ]; } && [ "$_mode" != "$_expected_mode" ]; then
    _yellow "Correcting permissions of $1 from ${_mode} to ${_expected_mode}"
    if ! chmod "$_expected_mode" "$1"; then
      _red "Failed to set permissions on user directory: $1"
      return 1
    fi
  elif [ "$_truenas" != true ] || [ "$_expected_mode" = 700 ]; then
    echo "Permissions are correct for $1: ${_mode}"
  else
    echo "Skipping permission-mode check on TrueNAS for $1"
  fi
  if [ "$_created" = true ]; then
    _green "Created user directory successfully: $1"
  fi
}

create_rootdir () {
  local _owner _group _mode _created=false
  if [ -d "$1" ]; then
    echo "Root directory already exists: $1"
  else
    echo "Creating root directory: $1"
    if ! mkdir -p "$1"; then
      _red "Failed to create root directory: $1"
      return 1
    fi
    _created=true
  fi

  if ! read -r _owner _group _mode < <(stat -c '%U %G %a' "$1"); then
    _red "Failed to inspect root directory: $1"
    return 1
  fi
  if [ "$_owner" != root ] || [ "$_group" != root ]; then
    _yellow "Correcting ownership of $1 from ${_owner}:${_group} to root:root"
    if ! chown -R root:root "$1" || ! chown root:root "$1"; then
      _red "Failed to set ownership on root directory: $1"
      return 1
    fi
  else
    echo "Ownership is correct for $1: root:root"
  fi
  if [ "$_truenas" != true ] && [ "$_mode" != 775 ]; then
    _yellow "Correcting permissions of $1 from ${_mode} to 775"
    if ! chmod 775 "$1"; then
      _red "Failed to set permissions on root directory: $1"
      return 1
    fi
  elif [ "$_truenas" != true ]; then
    echo "Permissions are correct for $1: ${_mode}"
  else
    echo "Skipping permission-mode check on TrueNAS for $1"
  fi
  if [ "$_created" = true ]; then
    _green "Created root directory successfully: $1"
  fi
}

create_userlink () {
  local _mode
  echo "Creating user symlink: $2 -> $1"
  if ! ln -sf "$1" "$2"; then
    _red "Failed to create user symlink: $2"
    return 1
  fi
  echo "Setting symlink ownership to ${_username}:${_usergroup}: $2"
  if ! chown -h "${_username}:${_usergroup}" "$2"; then
    _red "Failed to set ownership on user symlink: $2"
    return 1
  fi
  if [ "$2" = ".ssh/authorized_keys" ]; then
    if ! _mode=$(stat -c '%a' "$2"); then
      _red "Failed to inspect authorized_keys permissions: $2"
      return 1
    fi
    if [ "$_mode" != 600 ]; then
      _yellow "Correcting permissions of $2 from ${_mode} to 600"
      if ! chmod 600 "$2"; then
        _red "Failed to set permissions on authorized_keys: $2"
        return 1
      fi
    else
      echo "Permissions are correct for $2: ${_mode}"
    fi
  fi
  _green "Created user symlink successfully: $2 -> $1"
}

create_rootlink () {
  echo "Creating root symlink: $2 -> $1"
  if ! ln -sf "$1" "$2"; then
    _red "Failed to create root symlink: $2"
    return 1
  fi
  _green "Created root symlink successfully: $2 -> $1"
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

echo
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
echo
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
  install_fastfetch_manual || exit 1
fi
install_mc_client || exit 1
install_czkawka_cli || exit 1
set_user_bin_ownership || exit 1

echo
echo "------------------------------------------"
echo "   Applying user profile customizations"
echo "------------------------------------------"
echo

cd "$_homedir"
create_userdir "${_homedir}/.config"

if [ "$_truenas" = true ]; then
  _mc_client_path="${_homedir}/.bin/mc"
else
  _mc_client_path="/usr/local/bin/mc"
fi

if [ -x "$_mc_client_path" ]; then
  create_userdir "${_homedir}/.mc"
fi

create_userdir "${_homedir}/.config/fastfetch"
create_userdir "${_homedir}/.vim"
create_userdir "${_homedir}/.vim/colors"
create_userdir "${_homedir}/.ssh"
create_userlink "../linux-profile/conf/authorized_keys" ".ssh/authorized_keys"
create_userlink "linux-profile/conf/bashrc" ".bashrc"
create_userlink "linux-profile/conf/bash_aliases" ".bash_aliases"
create_userlink "linux-profile/conf/bash_profile" ".bash_profile"
create_userlink "../../linux-profile/conf/fastfetch.jsonc" ".config/fastfetch/config.jsonc"
create_userlink "linux-profile/conf/vimrc" ".vimrc"

echo
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
create_rootlink "linux-profile/conf/bash_profile" ".bash_profile"
create_rootlink "../../linux-profile/conf/fastfetch.jsonc" ".config/fastfetch/config.jsonc"
create_rootlink "linux-profile/conf/vimrc" ".vimrc"
