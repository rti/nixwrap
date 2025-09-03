#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

bwrap_opts=()

# environment variables always shared with the wrapped process
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
  XDG_RUNTIME_DIR
  XDG_SEAT
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

# paths shared read only by default
paths_general=(
  /nix
  /etc/nix
  /etc/static/nix

  /bin
  /usr/bin
  /lib
  /lib64
)

# paths that are not allowed to be shared as working directories implicitly,
# unless forced with -f
paths_disallowed_from_share_cwd=(
  "^/$"
  "^/home$"
  "^${HOME}$"

  "^/boot"
  "^/etc"
  "^/proc"
  "^/run"
  "^/sys"
  "^/var"
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

Usage: wrap [OPTIONS] [-- BWRAP_ARGS] PROGRAM_TO_WRAP_WITH_ARGS

OPTIONS:
  -d       Allow Desktop access, Wayland, X11, and rendering hardware.
  -n       Allow Network access.
  -a       Allow Audio access.
  -c       Allow Camera access.
  -b       Allow DBus access.
  -u       Allow System user information access.
  -e VAR   Allow env var VAR access.
  -r PATH  Mount PATH into sandbox in read-only mode.
  -w PATH  Mount PATH into sandbox in read write mode.
  -v       Verbose output for debugging.

ADVANCED OPTIONS:
  -p       Do not share current working directory. By default wrap will share 
           the current working directory as a write mount and cd into it 
           before running the program. With this option, wrap will not share 
           the directory and leave the current directory untouched.
  -f       Force share current working directory. By default wrap will share
           the current working directory as a write mount and cd into it only
           if the directory does not match any of the following patterns: 
           ^/$, ^/home$, ^\${HOME}$, ^/boot, ^/etc, ^/proc, ^/run, ^/sys, ^/var
           This option will bypass the check and share the directory regardless. 
  -m       Manual unsharing. By default wrap unshares ipc, net, pid, and uts 
           and tries to unshare (continue on failures) user and cgroup 
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
force_share_cwd=0

while getopts "r:w:e:abcdfhmnpuv" opt; do
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

  # grant desktop access (Wayland or X11) and rendering hardware access
  d)
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      # Using Wayland: bind the Wayland display socket
      bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY")
    fi

    if [ -n "${DISPLAY:-}" ]; then
      # Using X11: bind the X11 socket directory
      # The standard location is usually /tmp/.X11-unix.
      if [ -d "/tmp/.X11-unix" ]; then
        bwrap_opts+=(--ro-bind "/tmp/.X11-unix" "/tmp/.X11-unix")
      fi

      # Bind the .Xauthority file so that the authorization data is available.
      if [ -n "${XAUTHORITY:-}" ]; then
        # Bind a custom path Xauthority file to the standard path in the sandbox
        bwrap_opts+=(--ro-bind "${HOME}/${XAUTHORITY}" "$HOME/.Xauthority")
      elif [ -f "$HOME/.Xauthority" ]; then
        # Bind the standard path Xauthority file to the sandbox
        bwrap_opts+=(--ro-bind "$HOME/.Xauthority" "$HOME/.Xauthority")
      fi
    fi

    if [ -d /dev/dri ]; then
      bwrap_opts+=(--dev-bind /dev/dri /dev/dri)
    fi

    if [ -d /run/opengl-driver ]; then
      bwrap_opts+=(--ro-bind /run/opengl-driver /run/opengl-driver)
    fi

    if [ -d /sys ]; then
      bwrap_opts+=(--ro-bind /sys/ /sys/)
    fi

    if [ -d /etc/fonts ]; then
      bwrap_opts+=(--ro-bind /etc/fonts /etc/fonts)
    fi

    # Append all desktop-related env variables
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

  # grant access to user information
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

  # by default nixwrap will NOT share the current working directory for a set
  # of possibly sensitive paths. this overwrides this and forces to share these
  # paths (see paths_disallowed_from_share_cwd)
  f) 
    force_share_cwd=1
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
  esac
done

# Shift off the options and optional -- off $@.
shift $((OPTIND - 1))

# Get the current working directory
cwd="$(pwd)"

# The directory to change to after launching the sandbox
bwrap_chdir="$HOME"

if [[ $unshare_all -eq 1 ]]; then
  bwrap_opts+=(--unshare-all "${bwrap_opts[@]}")
fi

# Check for paths we do not want to share implicitly if we are not forced to
if [[ $force_share_cwd -eq 0 ]]; then
  for p in "${paths_disallowed_from_share_cwd[@]}"; do
    if [[ "$cwd" =~ $p ]]; then
      # Disable current working directory sharing if pattern matches
      share_cwd=0
      break
    fi
  done
fi

if [[ $share_cwd -eq 1 ]]; then
  bwrap_opts+=(--bind "$cwd" "$cwd")
  bwrap_chdir="$cwd"
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
  if [ -d "$p" ]; then
    bwrap_opts+=(--ro-bind "$p" "$p")
  fi
done

for e in "${env_vars[@]}"; do
  if [ -v "$e" ]; then
    bwrap_opts+=(--setenv "$e" "${!e}")
  fi
done

exec bwrap \
  --chdir "$bwrap_chdir" \
  --clearenv \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --bind "$TMPDIR" "$TMPDIR" \
  --dir "$HOME" \
  "${bwrap_opts[@]}" \
  "$@"
