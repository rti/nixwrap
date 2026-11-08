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
  -n       Allow Network access, without sharing host loopback or abstract sockets.
  -N       Keep the caller's network, including loopback and abstract sockets.
  -P PORT  With -n, allow TCP access to this host loopback port; repeatable.
  -I IFACE Allow Network access only through host interface IFACE (implies -n).
  -a       Allow Audio access.
  -c       Allow Camera access.
  -b       Allow DBus access.
  -u       Allow System user information access.
  -e VAR   Allow env var VAR access.
  -r PATH  Mount PATH into sandbox in read-only mode.
  -w PATH  Mount PATH into sandbox in read write mode.
  -s PATH  Share PATH's Nix runtime closure read-only instead of all of /nix and NIX_PROFILES.
  -H PATH  Use PATH as persistent home storage, mounted writable at the caller's HOME.
           HOME and explicit -r/-w mount paths stay unchanged inside the sandbox.
  -v       Verbose output for debugging.

ADVANCED OPTIONS:
  -p       Do not implicitly mount the current working directory writable.
           Takes precedence over -f. The launch directory is preserved if it
           exists inside the sandbox; otherwise bubblewrap falls back to HOME.
  -f       **DEPRECATED** Will be removed in the future, use -w or -r.
           Force share current working directory. By default wrap will share
           the current working directory as a write mount and cd into it only
           if it is not the caller's home and does not match these patterns:
           ^/$, ^/home$, ^/boot, ^/etc, ^/proc, ^/run, ^/sys, ^/var
           This option bypasses that check, but does not override -p.
END_OF_USAGE
}

# Match path components, not just prefixes: /foo does not contain /foobar.
path_is_covered() {
  local path="$1" parent
  shift
  for parent in "$@"; do
    if [[ "$parent" == / || "$path" == "$parent" || "$path" == "$parent/"* ]]; then
      return 0
    fi
  done
  return 1
}

# Return success if $1 (the physical cwd from pwd -P) may be shared writable.
# -p always disables sharing. Otherwise -f bypasses the HOME identity check
# and protected-path patterns; without -f, either match prevents sharing.
# TODO: -p -f is cursed, we should deprecate it, manual -r/-w can do the same
should_share_cwd() {
  local cwd="$1" pattern
  [[ $share_cwd -eq 1 ]] || return 1
  [[ $force_share_cwd -eq 0 ]] || return 0
  [[ "$cwd" -ef "$HOME" ]] && return 1
  for pattern in "${paths_disallowed_from_share_cwd[@]}"; do
    [[ "$cwd" =~ $pattern ]] && return 1
  done
  return 0
}

# Add read-only paths without mounting over symlinks exposed by earlier binds.
mount_readonly_paths() {
  local p resolved destination
  for p in "$@"; do
    [[ -d "$p" ]] || continue
    resolved="$(readlink -f -- "$p")"

    # A symlink needs both its name and target supplied by read-only mounts.
    if path_is_covered "$p" "${readonly_mounts[@]}" &&
      path_is_covered "$resolved" "${readonly_mounts[@]}"; then
      continue
    fi

    destination="$p"
    if path_is_covered "$p" "${bound_paths[@]}"; then
      destination="$resolved"
    fi
    bwrap_opts+=(--ro-bind "$p" "$destination")
    bound_paths+=("$destination")
    readonly_mounts+=("$destination")
  done
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

share_cwd=1
force_share_cwd=0
home_source=""
network=0
host_ports=""
outbound_interface=""
explicit_mounts=()
store_roots=()
store_bin_path=""
xauth_src=""

while getopts "r:w:s:e:H:P:I:abcdfhnNpuv" opt; do
  case "$opt" in

  s)
    store_roots+=("$OPTARG")
    ;;

  # Collect explicit mounts; apply them after persistent home storage.
  r | w)
    [[ -e "$OPTARG" ]] || mkdir -p "$OPTARG"
    if [[ "$opt" == r ]]; then
      explicit_mounts+=(--ro-bind "$OPTARG" "$OPTARG")
    else
      explicit_mounts+=(--bind "$OPTARG" "$OPTARG")
    fi
    ;;

  # Select persistent home storage without changing HOME; the last -H wins.
  H)
    [[ -e "$OPTARG" ]] || mkdir -p "$OPTARG"
    home_source="$OPTARG"
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
      # Socket names are relative to XDG_RUNTIME_DIR; absolute paths are not.
      if [[ "$WAYLAND_DISPLAY" = /* ]]; then
        wayland_socket="$WAYLAND_DISPLAY"
      else
        wayland_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      fi
      if [ -e "$wayland_socket" ]; then
        bwrap_opts+=(--bind "$wayland_socket" "$wayland_socket")
      fi
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

  # Select isolated or inherited networking; the last option wins.
  n | N | I)
    network="$opt"
    if [[ "$opt" == I ]]; then
      network=n
      if [[ -z "$OPTARG" ]]; then
        echo "Error: -I requires a non-empty interface name." >&2
        exit 1
      fi
      outbound_interface="$OPTARG"
    fi
    ;;

  P)
    if [[ ! "$OPTARG" =~ ^[1-9][0-9]{0,4}$ ]] || (( OPTARG > 65535 )); then
      echo "Invalid host TCP port: $OPTARG (expected 1-65535)" >&2
      exit 1
    fi
    host_ports+="${host_ports:+,}$OPTARG"
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

# Check if TIOCSTI is enabled in the kernel and --new-session is not provided.
# TIOCSTI can be used to escape the sandbox (CVE-2017-5226).
# https://github.com/containers/bubblewrap/issues/142
if [[ -f /proc/sys/dev/tty/legacy_tiocsti ]] && [[ "$(cat /proc/sys/dev/tty/legacy_tiocsti)" == "1" ]]; then
  has_new_session=0
  for arg in "$@"; do
    if [[ "$arg" == "--new-session" ]]; then
      has_new_session=1
      break
    fi
  done
  if [[ $has_new_session -eq 0 ]]; then
    echo "Error: dev.tty.legacy_tiocsti is enabled. TIOCSTI ioctl can be used to escape the sandbox (CVE-2017-5226)." >&2
    echo "Please add --new-session to your bwrap arguments." >&2
    echo "  Example: wrap -- --new-session your-program" >&2
    exit 1
  fi
fi

# Assemble path mounts in precedence order. Later mounts override earlier ones.
bound_paths=()
# Track already-mounted read-only destinations to skip redundant mounts.
readonly_mounts=()

# 1. General defaults; retain standalone aliases such as /bin.
if (( ${#store_roots[@]} )); then
  # Query before launching so an invalid root cannot silently yield a partial sandbox.
  nix-store --query --requisites "${store_roots[@]}" >"$TMPDIR/store-paths"
  while IFS= read -r store_path; do
    bwrap_opts+=(--ro-bind "$store_path" "$store_path")
  done <"$TMPDIR/store-paths"
  # Only explicit roots contribute commands, in -s order; leave the host PATH alone.
  for store_root in "${store_roots[@]}"; do
    store_root="$(readlink -f -- "$store_root")"
    if [[ -d "$store_root/bin" ]]; then
      store_bin_path+="${store_bin_path:+:}$store_root/bin"
    fi
  done
else
  mount_readonly_paths /nix
fi
mount_readonly_paths "${paths_general[@]}"

# 2. Persistent home storage, without changing HOME.
if [[ -n "$home_source" ]]; then
  bwrap_opts+=(--bind "$home_source" "$HOME")
  # A writable overlay may hide earlier read-only mounts.
  readonly_mounts=()
fi

# 3. Implicit writable cwd, subject to -p, -f, and protected-path rules.
cwd="$(pwd -P)"
if should_share_cwd "$cwd"; then
  bwrap_opts+=(--bind "$cwd" "$cwd")
  bound_paths+=("$cwd")
  readonly_mounts=()
fi

# 4. Profiles must survive home/cwd overlays and remain read-only by default.
readonly_paths=()
if (( ${#store_roots[@]} == 0 )) && [ -v NIX_PROFILES ]; then
  OLDIFS=$IFS
  IFS=" "
  for p in ${NIX_PROFILES}; do
    readonly_paths+=("$p")
  done
  IFS=$OLDIFS
fi
mount_readonly_paths "${readonly_paths[@]}"

# 5. Explicit requests have the final say, in argument order.
bwrap_opts+=("${explicit_mounts[@]}")

# Desktop sources use the host HOME; mount auth after any sandbox-home binds.
if [[ -n "$xauth_src" ]]; then
  bwrap_opts+=(--ro-bind-try "$xauth_src" "$HOME/.Xauthority")
fi

# Namespace isolation is always enabled.
bwrap_opts=(--unshare-all "${bwrap_opts[@]}")

# Environment variables
for e in "${env_vars[@]}"; do
  if [ -v "$e" ]; then
    bwrap_opts+=(--setenv "$e" "${!e}")
  fi
done
if [[ -n "$store_bin_path" ]]; then
  bwrap_opts+=(--setenv PATH "${store_bin_path}${PATH:+:$PATH}")
fi
bwrap_opts+=(--setenv HOME "$HOME")

if [[ -n "$host_ports" && "$network" != n ]]; then
  echo "-P requires isolated networking (-n), not -N or the default mode" >&2
  exit 1
fi

# Both network modes use the caller's certificates.
if [[ "$network" != 0 ]]; then
  bwrap_opts+=(--ro-bind /etc/ssl /etc/ssl)
  bwrap_opts+=(--ro-bind /etc/static/ssl /etc/static/ssl)
fi

# Only -n starts pasta; -N directly retains the caller's network namespace.
pasta_launch=()
if [[ "$network" == N ]]; then
  bwrap_opts+=(--share-net --ro-bind /etc/resolv.conf /etc/resolv.conf)
elif [[ "$network" == n ]]; then
  IFS= read -r sandbox_hostname </proc/sys/kernel/hostname
  sandbox_hostname+="-wrap"
  bwrap_opts+=(--hostname "$sandbox_hostname")
  dns_forward=169.254.1.1
  bwrap_opts+=(--share-net --ro-bind "$TMPDIR/resolv.conf" /etc/resolv.conf)
  # pasta maps the caller to root; restore its numeric identity in an inner userns.
  bwrap_opts+=(--uid "$UID" --gid "$(id -g)")
  pasta_launch=(pasta --config-net --ns-ifname wrap0 --no-map-gw --hostname "$sandbox_hostname"
    --tcp-ports none --udp-ports none --tcp-ns "${host_ports:-none}" --udp-ns none
    --dns-forward "$dns_forward")
  if [[ -n "$outbound_interface" ]]; then
    ipv4_addresses="$(ip -o -4 address show dev "$outbound_interface")"
    ipv6_addresses="$(ip -o -6 address show dev "$outbound_interface" scope global)"
    if [[ -n "$ipv4_addresses" ]]; then
      # A link-local guest subnet keeps the resolver reachable with /32 host addresses.
      pasta_launch+=(--outbound-if4 "$outbound_interface"
        --address 169.254.2.1/24 --gateway 169.254.2.2)
    fi
    if [[ -n "$ipv6_addresses" ]]; then
      pasta_launch+=(--outbound-if6 "$outbound_interface" --gateway fe80::1)
    fi
    if [[ -z "$ipv6_addresses" && -n "$ipv4_addresses" ]]; then
      pasta_launch+=(--ipv4-only)
    elif [[ -z "$ipv4_addresses" && -n "$ipv6_addresses" ]]; then
      dns_forward=fd00::1
      pasta_launch+=(--ipv6-only --dns-forward "$dns_forward")
    elif [[ -z "$ipv4_addresses" && -z "$ipv6_addresses" ]]; then
      echo "Error: interface $outbound_interface has no usable IP addresses." >&2
      exit 1
    fi
  fi
  printf 'nameserver %s\n' "$dns_forward" >"$TMPDIR/resolv.conf"
  pasta_launch+=(--)
fi

# Finally: Launch it
exec "${pasta_launch[@]}" bwrap \
  --clearenv \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --bind "$TMPDIR" "$TMPDIR" \
  --dir "$HOME" \
  "${bwrap_opts[@]}" \
  "$@"
