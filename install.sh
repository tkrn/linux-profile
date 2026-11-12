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
  local _mc_arch _mc_tmp
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

  if ! chmod +x "$_mc_tmp" || ! install -m 0755 "$_mc_tmp" /usr/local/bin/mc; then
    rm -f "$_mc_tmp"
    echo "Failed to install the MinIO mc client." >&2
    return 1
  fi
  rm -f "$_mc_tmp"

  mc --version || return 1
}

create_userdir () {
  mkdir -p $1
  chown $(logname):$(logname) $1 -R
  chmod 775 $1 
}

create_rootdir () {
  mkdir -p $1
  chmod 775 $1 
}
create_userlink () {
  ln -sf $1 $2
  chown $(logname):$(logname) $2
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
  [minicom]="minicom"
  [less]="less"
  [wget]="wget"
  [curl]="curl"
  [rsync]="rsync"
  [vim]="vim-enhanced"
)

_scriptpath="$(dirname "$(readlink -f "$0")")"
_debug "_scriptpath -> $_scriptpath"

_homedir=$(getent passwd $(logname) | awk -F: '{print $6}')
_debug "_homedir -> $_homedir"

_rootdir=$(getent passwd root | awk -F: '{print $6}')
_debug "_rootdir -> $_rootdir"

_os=$(uname | tr '[:upper:]' '[:lower:]')
_debug "_os -> $_os"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  _distro="${ID,,}"
else
  echo "Unable to determine Linux distribution: /etc/os-release is unavailable." >&2
  exit 1
fi
_debug "_distro -> $_distro"

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

clean bashrc
clean bash_profile
clean bash_logout

case "$_distro" in
  debian|ubuntu|raspbian) apt_update || exit 1 ;;
  rocky) dnf_update || exit 1 ;;
esac
check_apps

if [ ${#_install[@]} -gt 0 ]; then
  install_apps || exit 1
fi
install_mc_client || exit 1

echo "------------------------------------------"
echo "   Applying user profile customizations"
echo "------------------------------------------"
echo

cd "$_homedir"
create_userdir "${_homedir}/.config/fastfetch"
create_userdir "${_homedir}/.vim/colors"
create_userdir "${_homedir}/.ssh"
chmod 700 "${_homedir}/.ssh"
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
