#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

bwrap_opts=()

# environment variables always shared with the wrapped process
# for usability and convenience
env_vars=(
  EDITOR
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

  XDG_CURRENT_DESKTOP
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
  -H PATH  Set and writable-mount the sandbox HOME path.
           Mounts -r/-w paths from host HOME at matching sandbox HOME.
  -v       Verbose output for debugging.

ADVANCED OPTIONS:
  -p       Do not implicitly mount the current working directory writable.
           Takes precedence over -f. The launch directory is preserved if it
           exists inside the sandbox; otherwise bubblewrap falls back to HOME.
           A launch from the unshared caller HOME starts in the sandbox HOME.
  -f       Force share current working directory. By default wrap will share
           the current working directory as a write mount and cd into it only
           if it is not the caller's home and does not match these patterns:
           ^/$, ^/home$, ^/boot, ^/etc, ^/proc, ^/run, ^/sys, ^/var
           This option bypasses that check, but does not override -p.
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
sandbox_home="$HOME"
mount_opts=()
xauth_src=""

while getopts "r:w:e:H:abcdfhmnpuv" opt; do
  case "$opt" in

  # bind / mount a path readonly in sandbox.
  # queue explicit mounts until the final sandbox home is known.
  r)
    # Create a directory if the path does not exist
    [[ -e "$OPTARG" ]] || mkdir -p "$OPTARG"

    mount_opts+=(--ro-bind "$OPTARG" "$OPTARG")
    ;;

  # bind / mount a path read/write in sandbox.
  # queue explicit mounts until the final sandbox home is known.
  w)
    # Create a directory if the path does not exist
    [[ -e "$OPTARG" ]] || mkdir -p "$OPTARG"

    mount_opts+=(--bind "$OPTARG" "$OPTARG")
    ;;

  # Mount the sandbox home before explicit mounts into it.
  H)
    [[ "$OPTARG" = /* ]] || OPTARG="$PWD/$OPTARG"
    sandbox_home="$OPTARG"
    [[ -e "$OPTARG" ]] || mkdir -p "$OPTARG"
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
    fi

    # Bind the .Xauthority file so that the authorization data is available.
    # Intentionally outside DISPLAY check so `wrap -d` exposes auth data even
    # without DISPLAY set.
    if [ -n "${XAUTHORITY:-}" ]; then
      # XAUTHORITY may be absolute or relative to $HOME (e.g. `myxauthfile`)
      if [[ "$XAUTHORITY" = /* ]]; then
        xauth_src="$XAUTHORITY"
      else
        xauth_src="$HOME/$XAUTHORITY"
      fi
    elif [ -f "$HOME/.Xauthority" ]; then
      xauth_src="$HOME/.Xauthority"
    fi

    if [ -d /dev/dri ]; then
      bwrap_opts+=(--dev-bind /dev/dri /dev/dri)
    fi

    # AMD kernel fusion driver
    if [ -e /dev/kfd ]; then
      bwrap_opts+=(--dev-bind /dev/kfd /dev/kfd)
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

# Keep host sources unchanged, but relocate explicit HOME mounts in the sandbox.
if [[ "$sandbox_home" != "$HOME" ]]; then
  host_home="${HOME%/}"
  for ((i = 0; i < ${#mount_opts[@]}; i += 3)); do
    source="${mount_opts[i + 1]}"
    if [[ "$source" == "$HOME" || "$source" == "$host_home" ]]; then
      mount_opts[i + 2]="$sandbox_home"
    elif [[ "$source" == "$host_home/"* ]]; then
      mount_opts[i + 2]="${sandbox_home%/}/${source#"$host_home/"}"
    fi
  done
fi
bwrap_opts+=("${mount_opts[@]}")

# Resolve symlinks before checking whether the working directory may be shared.
cwd="$(pwd -P)"

if [[ $unshare_all -eq 1 ]]; then
  bwrap_opts=(--unshare-all "${bwrap_opts[@]}")
fi

# Check for paths we do not want to share implicitly if we are not forced to
if [[ $force_share_cwd -eq 0 ]]; then
  if [[ "$cwd" -ef "$HOME" ]]; then
    share_cwd=0
  fi
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
elif [[ "$cwd" -ef "$HOME" ]]; then
  # A launch from the caller's home should start in the sandbox home.
  bwrap_opts+=(--chdir "$sandbox_home")
fi

if [ -v NIX_PROFILES ]; then
  OLDIFS=$IFS
  IFS=" "
  for p in ${NIX_PROFILES}; do
    paths_general+=("$p")
  done
  IFS=$OLDIFS
fi

for p in "${paths_general[@]}"; do
  if [ -d "$p" ]; then
    destination="$p"
    # A shared ancestor already supplies host symlinks. Mount their targets
    # directly: bwrap cannot create mountpoints through those symlinked paths.
    if [[ $share_cwd -eq 1 && ( "$cwd" == / || "$p" == "$cwd" || "$p" == "$cwd/"* ) ]]; then
      destination="$(readlink -f -- "$p")"
    fi
    bwrap_opts+=(--ro-bind "$p" "$destination")
  fi
done

# Desktop sources use the host HOME; mount auth after any sandbox-home binds.
if [[ -n "$xauth_src" ]]; then
  bwrap_opts+=(--ro-bind-try "$xauth_src" "$sandbox_home/.Xauthority")
fi

for e in "${env_vars[@]}"; do
  if [ -v "$e" ]; then
    bwrap_opts+=(--setenv "$e" "${!e}")
  fi
done
bwrap_opts+=(--setenv HOME "$sandbox_home")

exec bwrap \
  --clearenv \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --bind "$TMPDIR" "$TMPDIR" \
  --dir "$sandbox_home" \
  "${bwrap_opts[@]}" \
  "$@"
