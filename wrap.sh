#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

bwrap_opts=()

# environment variables alwyas shared with the wrapped process
# for usability and convenience
env_vars=(
  EDITOR
  HOME
  INFOPATH
  LD_LIBRARY_PATH
  LIBEXEC_PATH
  PAGER
  PATH
  PKG_CONFIG_PATH
  PWD
  SHELL

  TERM
  TERMINFO
  TERMINFO_DIRS

  XDG_BIN_HOME
  XDG_CACHE_HOME
  XDG_CONFIG_DIRS
  XDG_CONFIG_HOME
  XDG_CURRENT_DESKTOP
  XDG_DATA_DIRS
  XDG_DATA_HOME
  XDG_DESKTOP_PORTAL_DIR
  XDG_RUNTIME_DIR XDG_SEAT
  XDG_SESSION_CLASS
  XDG_SESSION_ID
  XDG_SESSION_TYPE
  XDG_VTNR

  NIXPKGS_ALLOW_UNFREE
  NIXPKGS_CONFIG
  NIX_PATH
  NIX_PROFILES
  NIX_USER_PROFILE_DIR

  LANG
  LC_ADDRESS
  LC_IDENTIFICATION
  LC_MEASUREMENT
  LC_MONETARY
  LC_NAME
  LC_NUMERIC
  LC_PAPER
  LC_TELEPHONE
  LC_TIME
  LOCALE_ARCHIVE
  LOCALE_ARCHIVE_2_27
  TZDIR
)

# environment variables only shared with the wrapped process
# when running with -d desktop access
env_vars_desktop=(
  DISPLAY
  WAYLAND_DISPLAY

  DESKTOP_STARTUP_ID

  BROWSER

  GDK_BACKEND
  GTK2_RC_FILES
  GTK_A11Y
  GTK_PATH

  MOZ_ENABLE_WAYLAND
  NIXOS_OZONE_WL
  QT_QPA_PLATFORM
  QT_WAYLAND_DISABLE_WINDOWDECORATION
  QT_WAYLAND_FORCE_DPI
  SDL_VIDEODRIVER
  VDPAU_DRIVER

  WLR_LIBINPUT_NO_DEVICES

  XCURSOR_PATH
  XCURSOR_SIZE
  XCURSOR_THEME
)

# paths shared read only be default
paths_general=(
  /nix
  /etc/nix
  /etc/static/nix

  /bin
  /usr/bin
)

usage() {
  cat <<END_OF_LOGO
 _ __ (_)_  ____      ___ __ __ _ _ __  
| '_ \\| \\ \\/ /\\ \\ /\\ / / '__/ _\` | '_ \\ 
| | | | |>  <  \\ V  V /| | | (_| | |_) |
|_| |_|_/_/\\_\\  \\_/\\_/ |_|  \\__,_| .__/ 
                                 |_|   
END_OF_LOGO
  cat <<END_OF_USAGE

Usage: wrap [OPTIONS] -- [bwrap args] [program to wrap with args]

OPTIONS:
  -w PATH  Mount PATH into sandbox in read write mode.
  -r PATH  Mount PATH into sandbox in read-only mode.
  -d       Allow Wayland display and rendering hardware access.
  -b       Allow DBus access.
  -n       Allow Network access.
  -a       Allow Audio access.
  -c       Allow Camera access.
  -u       Allow System user information access.
  -e VAR   Allow env var VAR access.
  -v       Verbose output for debugging.

ADVANCED OPTIONS:
  -p       Do not share current working directory. By default wrap will share 
           the current working directory as a write mount and cd into it 
           before running the program. With this option, wrap will not share 
           the directory and leave the current directory untouched.
  -m       Manual unsharing. By default wrap unshares ipc, net, pid, and uts 
           and tries to unshare (continue on failues) user and cgroup 
           namespaces. With this option, wrap does not automatically unshare 
           any namespaces. Use together with bwrap --unshare-* options 
           (man bwrap(1)) to unshare manually.
END_OF_USAGE
}

TMPDIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMPDIR"
}

trap cleanup EXIT

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

unshare_all=1
share_cwd=1

while getopts "r:w:e:abcdhmnpuv" opt; do
  case "$opt" in

  # bind / mount a path readonly in sandbox to the same path as host
  r)
    bwrap_opts+=(--ro-bind "$OPTARG" "$OPTARG")
    ;;

  # bind / mount a path read/write in sandbox to the same path as host
  w)
    bwrap_opts+=(--bind "$OPTARG" "$OPTARG")
    ;;

  # grant access to camera device
  c)
    bwrap_opts+=(--dev-bind "/dev/v4l" "/dev/v4l")
    for i in /dev/video*; do
      bwrap_opts+=(--dev-bind "$i" "$i")
    done
    ;;

  # grant access to dbus system
  b)
    dbus_socket="$(echo "$DBUS_SESSION_BUS_ADDRESS" | cut -d= -f2)"
    bwrap_opts+=(--bind "$dbus_socket" "$dbus_socket")
    env_vars+=(DBUS_SESSION_BUS_ADDRESS)
    ;;

  # grant desktop access, wayland, X11, DRI
  d)
    bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY")

    if [ -f /dev/dri ]; then
      bwrap_opts+=(--dev-bind /dev/dri /dev/dri)
    fi

    if [ -f /run/opengl-driver ]; then
      bwrap_opts+=(--ro-bind /run/opengl-driver /run/opengl-driver)
    fi

    if [ -f /sys ]; then
      bwrap_opts+=(--ro-bind /sys/ /sys/)
    fi

    if [ -f /etc/fonts ]; then
      bwrap_opts+=(--ro-bind /etc/fonts /etc/fonts)
    fi

    env_vars+=("${env_vars_desktop[@]}")
    ;;

  # grant network access
  n)
    bwrap_opts+=(--share-net)
    bwrap_opts+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
    bwrap_opts+=(--ro-bind /etc/ssl /etc/ssl)
    bwrap_opts+=(--ro-bind /etc/static/ssl /etc/static/ssl)
    ;;

  # grant audio access
  a)
    bwrap_opts+=(--bind-try "$XDG_RUNTIME_DIR/pulse/native" "$XDG_RUNTIME_DIR/pulse/native")
    bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
    bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/pipewire-0.lock" "$XDG_RUNTIME_DIR/pipewire-0.lock")
    ;;

  # grant accss to user information
  u)
    bwrap_opts+=(--ro-bind /etc/passwd /etc/passwd)
    bwrap_opts+=(--ro-bind /etc/group /etc/group)
    env_vars+=(USER)
    ;;

  # manually grant access to additional environment variables
  e)
    env_vars+=("$OPTARG")
    ;;

  # by default nixwrap will run bwrap with --unshare-all,
  # this disables it, see man bwrap(1)
  m)
    unshare_all=0
    ;;

  # by default nixwrap will share the current working directory
  # with the wrapped process, this disables it
  p)
    share_cwd=0
    ;;

  # verbose script outputs for debugging
  v)
    set -x
    ;;

  # help - display usage information
  h)
    usage
    exit 0
    ;;

  \?)
    usage
    exit 1
    ;;
  :)
    usage
    exit 1
    ;;
  *) ;;
  esac
done

# Shift off the options and optional -- off $@.
shift $((OPTIND - 1))

if [[ $unshare_all -eq 1 ]]; then
  bwrap_opts+=(--unshare-all "${bwrap_opts[@]}")
fi

if [[ $share_cwd -eq 1 ]]; then
  cwd="$(pwd)"
  bwrap_opts+=(--bind "$cwd" "$cwd")
  bwrap_opts+=(--chdir "$cwd")
fi

if [ -v NIX_PROFILES ]; then
  OLDIFS=$IFS
  IFS=" "
  for p in ${NIX_PROFILES}; do
    if [[ -d "$p" ]]; then
      bwrap_opts+=(--ro-bind "$p" "$p")
    fi
  done
  IFS=$OLDIFS
fi

for p in "${paths_general[@]}"; do
  if [ -d $p ]; then
    bwrap_opts+=(--ro-bind "$p" "$p")
  fi
done

for e in "${env_vars[@]}"; do
  if [ -v "$e" ]; then
    bwrap_opts+=(--setenv "$e" "${!e}")
  fi
done

bwrap \
  --clearenv \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --bind "$TMPDIR" "$TMPDIR" \
  --dir "$HOME" \
  "${bwrap_opts[@]}" \
  "$@"
