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
  for x in ${!_pkgs[@]}; do
    if type $x > /dev/null 2>&1; then
      _debug "pkg -> found $x"	    
    else
      _install+=($x) 
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
  apt update
  apt install software-properties-common -y
  apt update

  if [ "$_distro" == "ubuntu" ]; then
    add-apt-repository ppa:zhangsongcui3371/fastfetch -y
  fi

  # Upgrade all packages automatically
  echo
  echo "Upgrading packages..."
  apt upgrade -y

  # (Optional) clean up
  echo
  echo "Cleaning up unnecessary packages..."
  apt autoremove -y
  apt autoclean -y

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
  
  for x in ${_install[@]}; do
    _installstring+="${_pkgs[$x]} " 
  done
  _debug "_installstring -> $_installstring" 
  
  apt install $_installstring -y
  
  echo "Cleaning up unnecessary packages..."
  apt autoremove -y
  apt autoclean -y

  echo
  echo "-------------------------------------"
  echo "   Applications installed!"
  echo "-------------------------------------"
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
declare -A _pkgs=()

_pkgs["ping"]="iputils-ping"
_pkgs["tmux"]="tmux"
_pkgs["git"]="git"
_pkgs["7z"]="7zip"
_pkgs["zip"]="zip"
_pkgs["screen"]="screen"
_pkgs["fastfetch"]="fastfetch"
_pkgs["htop"]="htop"
_pkgs["bashtop"]="bashtop"
_pkgs["btop"]="btop"
_pkgs["ifconfig"]="net-tools"
_pkgs["dig"]="dnsutils"
_pkgs["minicom"]="minicom"
_pkgs["less"]="less"
_pkgs["wget"]="wget"
_pkgs["curl"]="curl"
_pkgs["rsync"]="rsync"
_pkgs["vim"]="vim"

_scriptpath="$(dirname "$(readlink -f "$0")")"
_debug "_scriptpath -> $_scriptpath"

_homedir=$(getent passwd $(logname) | awk -F: '{print $6}')
_debug "_homedir -> $_homedir"

_rootdir=$(getent passwd root | awk -F: '{print $6}')
_debug "_rootdir -> $_rootdir"

_os=$(uname | tr '[:upper:]' '[:lower:]')
_debug "_os -> $_os"

_distro=$(lsb_release -a | awk '{print $2}' | sed -n '2p' | tr '[:upper:]' '[:lower:]')
_debug "_distro -> $_distro"

_codename=$(lsb_release -a | awk '{print $2}' | sed -n '4p' | tr '[:upper:]' '[:lower:]')
_debug "_codename -> $_codename"

clean bashrc
clean bash_profile
clean bash_logout

apt_update
check_apps

if [ ${#_install[@]} -gt 0 ]; then
  install_apps
fi

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
