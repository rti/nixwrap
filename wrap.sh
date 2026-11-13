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
  -B       Allow direct, unfiltered host session D-Bus access.
  -b ACTION:RULE
           Add a session D-Bus permission; repeatable.
           Actions: call, broadcast, talk, own, see.
           RULE uses xdg-dbus-proxy syntax: NAME[=INTERFACE.METHOD@/PATH].
  -u       Allow System user information access.
  -e VAR   Allow env var VAR access.
  -r PATH  Mount PATH into sandbox in read-only mode.
  -w PATH  Mount PATH into sandbox in read write mode.
  -s PATH  Share PATH's Nix runtime closure read-only instead of all of /nix and NIX_PROFILES.
  -H PATH  Use PATH as persistent home storage, mounted writable at the caller's HOME.
           HOME and explicit -r/-w mount paths stay unchanged inside the sandbox.
  --allowed-egress-tcp DOMAIN:PORT | ADDRESS:PORT
           Allow exactly this one TCP endpoint out of the sandbox; repeatable.
           In the default network-less mode it is the sandbox's only way out.
           With -n or -I it also works, as a direct host-resolved path to the
           endpoint next to pasta's unrestricted egress. A domain is resolved
           by the caller before the sandbox starts and the answer is published
           to the session in a generated /etc/hosts. The address, resolved or
           given, is assigned to the session's loopback interface, and the
           endpoint is tunnelled to the caller's network namespace through a
           unix socket in wrap's private directory. Alias: --allow. IPv4 only.
  --allowed-egress-udp DOMAIN:PORT | ADDRESS:PORT
           Same as --allowed-egress-tcp for one UDP endpoint; datagram
           boundaries are preserved and datagram flows are carried one at a
           time. Alias: --allow-udp.
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
dbus_proxy_pid=""
sandbox_pid=""

# Caller-side halves of --allowed-egress-tcp/udp tunnels; torn down with the
# session.
egress_pids=()

cleanup() {
  if [[ -n "$sandbox_pid" ]]; then
    kill "$sandbox_pid" 2>/dev/null || true
    wait "$sandbox_pid" 2>/dev/null || true
  fi
  if [[ -n "$dbus_proxy_pid" ]]; then
    kill "$dbus_proxy_pid" 2>/dev/null || true
    wait "$dbus_proxy_pid" 2>/dev/null || true
  fi
  # socat forks a handler per connection; signal the whole process group so a
  # handler cannot outlive the session and keep its sockets open.
  for pgroup in "${egress_pids[@]}"; do
    kill -- "-$pgroup" 2>/dev/null || true
  done
  rm -rf "$TMPDIR"
}

trap cleanup EXIT

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

# Long options are handled before getopts, which only knows single letters.
# Like getopts, parsing stops at the first non-option argument, so these names
# never collide with arguments of the wrapped command. Everything from a bare
# -- onwards is left for bwrap to interpret.
allowed_egress_tcp=()
allowed_egress_udp=()
short_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --)
    short_args+=("$@")
    break
    ;;
  --allowed-egress-tcp | --allow)
    if [[ $# -lt 2 ]]; then
      echo "Option $1 requires an argument: $1 DOMAIN:PORT" >&2
      exit 1
    fi
    allowed_egress_tcp+=("$2")
    shift 2
    ;;
  --allowed-egress-udp | --allow-udp)
    if [[ $# -lt 2 ]]; then
      echo "Option $1 requires an argument: $1 DOMAIN:PORT" >&2
      exit 1
    fi
    allowed_egress_udp+=("$2")
    shift 2
    ;;
  --allowed-egress-tcp=* | --allow=*)
    allowed_egress_tcp+=("${1#*=}")
    shift
    ;;
  --allowed-egress-udp=* | --allow-udp=*)
    allowed_egress_udp+=("${1#*=}")
    shift
    ;;
  -r | -w | -s | -e | -H | -P | -I)
    # A short option that takes an argument carries it along, so the scan
    # keeps looking for long options after it instead of mistaking the
    # argument for the wrapped command.
    if [[ $# -gt 1 ]]; then
      short_args+=("$1" "$2")
      shift 2
    else
      short_args+=("$1")
      shift
    fi
    ;;
  -?*)
    short_args+=("$1")
    shift
    ;;
  *)
    # The command; everything after it belongs to it.
    short_args+=("$@")
    break
    ;;
  esac
done
set -- "${short_args[@]}"

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
dbus_raw=0
dbus_rules=()

while getopts "r:w:s:e:H:P:I:b:BacdfhnNpuv" opt; do
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

  # Keep raw access explicit; filtered rules are assembled after parsing.
  B)
    dbus_raw=1
    ;;

  b)
    # Consume only the action separator; colons inside native rules are data.
    dbus_action=${OPTARG%%:*}
    dbus_rule=${OPTARG#*:}
    if [[ "$OPTARG" != *:* || -z "$dbus_rule" ]]; then
      echo "wrap: -b requires ACTION:RULE with a nonempty rule" >&2
      exit 1
    fi
    case "$dbus_action" in
      call | broadcast | talk | own | see)
        dbus_rules+=("--$dbus_action=$dbus_rule")
        ;;
      *)
        echo "wrap: unknown D-Bus action '$dbus_action'; expected call, broadcast, talk, own, or see" >&2
        exit 1
        ;;
    esac
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

# --allowed-egress-tcp and --allowed-egress-udp: the only way out of an
# otherwise network-less sandbox.
#
# The sandbox never gets a route to the network. wrap resolves the name in the
# caller's context, then bridges exactly one endpoint across the network
# namespace boundary with a unix socket inside $TMPDIR, which is bind-mounted
# into the session:
#
#   app -> HOST:PORT -> lo (HOST's address) -> socat in the session's netns
#       -> $TMPDIR/egress-N.sock -> socat in the caller's netns -> the network
#
# No firewall rules are involved: pasta, and wrap here, are userspace relays,
# so sandbox traffic only ever exists in the kernel as caller-owned sockets a
# host ruleset could not single out. Confinement is structural instead. The
# session's network namespace holds loopback and nothing else; the endpoint
# address is local to it, and every socket that leaves is created by the
# caller, outside the sandbox.
#
# The session joins a network namespace owned by a user namespace that wrap
# creates for it, instead of an empty one of bwrap's own: a network namespace
# can only be administered from the user namespace that created it, and bwrap
# creates its user namespace too late for that. So unshare makes user and
# network namespaces first, the loopback is addressed there, and bwrap runs
# with --share-net. The session sees the address on its own lo and nothing else.

# egress_netns is the prologue run in the session's network namespace; empty
# when the feature is off.
egress_netns=""

if (( ${#allowed_egress_tcp[@]} || ${#allowed_egress_udp[@]} )); then
  # -N is the one network mode that cannot host a tunnel: the session would
  # share the caller's own network namespace, and wrap cannot address its
  # loopback there. -n and -I run the tunnel alongside pasta's egress; the
  # allowlist then adds paths, it does not confine pasta.
  if [[ "$network" == N ]]; then
    echo "--allowed-egress-tcp/udp cannot be combined with -N; the tunnels need a network namespace of their own" >&2
    exit 1
  fi
  if [[ "$network" == n ]]; then
    echo "Note: with -n or -I, pasta keeps full egress through wrap0; --allowed-egress-* adds host-resolved endpoints but does not restrict pasta." >&2
  fi
  for tool in getent ip setsid socat unshare; do
    if ! command -v "$tool" >/dev/null; then
      echo "--allowed-egress-tcp requires $tool on PATH" >&2
      exit 1
    fi
  done
  egress_ip="$(readlink -f "$(command -v ip)")"
  egress_socat="$(readlink -f "$(command -v socat)")"
  egress_shell="$(readlink -f "$(command -v bash)")"
  # Used, when available, to wait for the listeners before the session starts.
  egress_ss=""
  if command -v ss >/dev/null; then
    egress_ss="$(readlink -f "$(command -v ss)")"
  fi

  # Only resolved names end up in /etc/hosts; a literal address needs no name.
  egress_hosts=""
  egress_netns='set -e
pids=""
stop() { for p in $pids; do kill -- "-$p" 2>/dev/null || true; done; }
trap stop EXIT
trap "exit 130" INT
trap "exit 143" TERM
'
  egress_netns+="$egress_ip link set lo up"$'\n'
  # SIG_IGN is inherited across exec: Ctrl-C belongs to the session, not to it.
  egress_netns+="trap '' INT"$'\n'
  egress_added=()
  egress_ports=()
  egress_index=0
  egress_tunnels=()

  # Endpoints tagged with their protocol, in the order they were given.
  egress_endpoints=()
  for spec in "${allowed_egress_tcp[@]}"; do
    egress_endpoints+=("tcp $spec")
  done
  for spec in "${allowed_egress_udp[@]}"; do
    egress_endpoints+=("udp $spec")
  done

  for endpoint in "${egress_endpoints[@]}"; do
    proto="${endpoint%% *}"
    spec="${endpoint#* }"
    if [[ ! "$spec" =~ ^([^[:space:],]+):([1-9][0-9]*)$ ]] ||
      (( BASH_REMATCH[2] > 65535 )); then
      echo "Invalid --allowed-egress-$proto value: $spec (expected DOMAIN:PORT)" >&2
      exit 1
    fi
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"

    address=""
    if [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
      if (( BASH_REMATCH[1] > 255 || BASH_REMATCH[2] > 255 ||
        BASH_REMATCH[3] > 255 || BASH_REMATCH[4] > 255 )); then
        echo "--allowed-egress-$proto: not an IPv4 address: $host" >&2
        exit 1
      fi
      address="$host"
    elif [[ "$host" == *:* ]]; then
      echo "--allowed-egress-$proto: IPv6 literals are not supported: $spec" >&2
      exit 1
    else
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          address="${line%% *}"
          break
        fi
      done < <(getent ahostsv4 "$host" || true)
      if [[ -z "$address" ]]; then
        echo "--allowed-egress-$proto: could not resolve an IPv4 address for $host" >&2
        exit 1
      fi
      egress_hosts+="$address $host"$'\n'
    fi

    if [[ "$address" == 127.* ]]; then
      echo "--allowed-egress-$proto: $host resolves to loopback ($address)" >&2
      exit 1
    fi

    # One tunnel per protocol, address and port; repeating a flag is a no-op.
    key="$proto/$address/$port"
    duplicate=0
    for taken in "${egress_tunnels[@]}"; do
      if [[ "$taken" == "$key" ]]; then
        duplicate=1
      fi
    done
    if (( duplicate )); then
      continue
    fi
    egress_tunnels+=("$key")

    # Caller-side half: accepts the unix socket and reaches the real address
    # from the caller's own network namespace. setsid gives it a process group
    # of its own, so wrap can take the listener and its connection handlers
    # down together.
    socket="$TMPDIR/egress-$egress_index.sock"
    if [[ "$proto" == tcp ]]; then
      setsid socat "UNIX-LISTEN:$socket,fork,mode=0600" "TCP:$address:$port" >/dev/null 2>&1 &
    else
      # A seqpacket socket (socktype 5) gives each datagram flow its own
      # connection and keeps datagram boundaries; -T drops a flow whose peer
      # fell silent. socat's UDP listener adopts one peer at a time, so flows
      # are carried one after another rather than side by side.
      setsid socat -T 10 "UNIX-LISTEN:$socket,socktype=5,fork,mode=0600" "UDP:$address:$port" >/dev/null 2>&1 &
    fi
    egress_pids+=($!)
    for _ in {1..100}; do
      if [[ -S "$socket" ]]; then
        break
      fi
      sleep 0.05
    done
    if [[ ! -S "$socket" ]]; then
      echo "--allowed-egress-tcp: failed to create $socket" >&2
      exit 1
    fi

    # Session-side half: the address is local to the session's namespace, so
    # the app connects to it on loopback and socat hands the connection over to
    # the unix socket. It runs in that namespace but outside the sandbox, which
    # keeps the sandbox free of forwarding tools and capabilities.
    seen=0
    for added in "${egress_added[@]}"; do
      if [[ "$added" == "$address" ]]; then
        seen=1
      fi
    done
    if (( ! seen )); then
      egress_netns+="$egress_ip addr add $address/32 dev lo"$'\n'
      egress_added+=("$address")
    fi
    if [[ "$proto" == tcp ]]; then
      egress_netns+="setsid $egress_socat TCP-LISTEN:$port,bind=$address,reuseaddr,fork UNIX-CONNECT:$socket >>$TMPDIR/egress-socat.log 2>&1 &"$'\n'
    else
      egress_netns+="setsid $egress_socat -T 10 UDP-LISTEN:$port,fork,bind=$address,reuseaddr UNIX-CONNECT:$socket,socktype=5 >>$TMPDIR/egress-socat.log 2>&1 &"$'\n'
    fi
    egress_netns+='pids="$pids $!"'$'\n'
    egress_ports+=("$port")
    egress_index=$((egress_index + 1))
  done

  egress_netns+="trap - INT"$'\n'

  # Give the listeners a moment to reach listen() before the session starts;
  # an app that connects first would otherwise see ECONNREFUSED. Start them
  # up, then refuse to launch the session at all if they never got there:
  # a sandbox that silently cannot use its only way out is worse than a
  # failed launch.
  if [[ -n "$egress_ss" ]]; then
    listening=""
    for port in "${egress_ports[@]}"; do
      listening+="${listening:+ && }\$ready == *\":$port \"*"
    done
    egress_netns+="for _ in {1..40}; do"$'\n'
    # -l without -t also reports the bound UDP sockets.
    egress_netns+="  ready=\"\$($egress_ss -ln || true)\""$'\n'
    egress_netns+="  if [[ $listening ]]; then break; fi"$'\n'
    egress_netns+="done"$'\n'
    egress_netns+="if [[ ! ( $listening ) ]]; then"$'\n'
    egress_netns+="  echo 'wrap: egress listeners failed to start' >&2"$'\n'
    # The listeners write their errors, and their polite exit on teardown, to
    # a log; show it only when the launch is actually failing.
    egress_netns+="  cat $TMPDIR/egress-socat.log >&2 2>/dev/null"$'\n'
    egress_netns+="  exit 1"$'\n'
    egress_netns+="fi"$'\n'
  fi
  egress_netns+='"$@"'$'\n'

  printf '%s' "$egress_netns" >"$TMPDIR/egress-netns.sh"

  # Resolved names need a /etc/hosts entry; a literal address needs no name.
  if [[ -n "$egress_hosts" ]]; then
    printf '127.0.0.1 localhost\n::1 localhost\n%s' "$egress_hosts" >"$TMPDIR/egress-hosts"
    bwrap_opts+=(--ro-bind "$TMPDIR/egress-hosts" /etc/hosts)
  fi
  # In the combined mode the pasta branch has already shared the namespace.
  if [[ "$network" != n ]]; then
    bwrap_opts+=(--share-net)
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

if (( dbus_raw || ${#dbus_rules[@]} )); then
  if (( dbus_raw && ${#dbus_rules[@]} )); then
    echo "wrap: -B cannot be combined with filtered D-Bus rules (-b)" >&2
    exit 1
  fi
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    echo "wrap: DBUS_SESSION_BUS_ADDRESS is required for D-Bus access" >&2
    exit 1
  fi
fi

if (( dbus_raw )); then
  # Preserve the host address and expose filesystem sockets without a proxy.
  # Addresses may contain fallback transports and optional fields such as guid.
  IFS=';' read -r -a dbus_addresses <<<"$DBUS_SESSION_BUS_ADDRESS"
  for dbus_address in "${dbus_addresses[@]}"; do
    [[ "$dbus_address" == unix:* ]] || continue
    IFS=',' read -r -a dbus_fields <<<"${dbus_address#unix:}"
    for dbus_field in "${dbus_fields[@]}"; do
      [[ "$dbus_field" == path=* ]] || continue
      dbus_socket=${dbus_field#path=}
      dbus_decoded=""
      while [[ "$dbus_socket" =~ ^([^%]*)%([[:xdigit:]]{2})(.*)$ ]]; do
        printf -v dbus_byte '%b' "\\x${BASH_REMATCH[2]}"
        dbus_decoded+="${BASH_REMATCH[1]}$dbus_byte"
        dbus_socket=${BASH_REMATCH[3]}
      done
      dbus_socket="$dbus_decoded$dbus_socket"
      bwrap_opts+=(--bind "$dbus_socket" "$dbus_socket")
    done
  done
  bwrap_opts+=(--setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS")
elif (( ${#dbus_rules[@]} )); then
  dbus_proxy_socket="$TMPDIR/session-bus"
  # The readiness byte comes only after listen() succeeds. Keeping a copy of
  # the pipe open ties the proxy to this supervisor; EOF also detects failure.
  coproc DBUS_PROXY {
    exec xdg-dbus-proxy --fd=1 "$DBUS_SESSION_BUS_ADDRESS" \
      "$dbus_proxy_socket" --filter "${dbus_rules[@]}"
  }
  dbus_proxy_pid=$DBUS_PROXY_PID
  exec {dbus_proxy_fd}<&"${DBUS_PROXY[0]}"
  if ! IFS= read -r -N 1 -t 10 <&"$dbus_proxy_fd"; then
    echo "wrap: D-Bus proxy failed to become ready" >&2
    exit 1
  fi
  bwrap_opts+=(--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$dbus_proxy_socket")
fi

if [[ -n "$host_ports" && "$network" != n ]]; then
  echo "-P requires isolated networking (-n), not -N or the default mode" >&2
  exit 1
fi

# Anything that can reach the network uses the caller's certificate
# authorities: -n and -N directly, --allowed-egress-tcp/udp through the tunnel.
if [[ "$network" != 0 || -n "$egress_netns" ]]; then
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

# The session's network namespace is administered from a user namespace that
# maps the caller to root, exactly as pasta does for -n. Without the same
# restoration, a session that reaches the network through a tunnel would run as
# root while -n runs as the caller. In the combined mode the pasta branch has
# already restored the identity.
if [[ -n "$egress_netns" && "$network" != n ]]; then
  bwrap_opts+=(--uid "$UID" --gid "$(id -g)")
fi

bwrap_cmd=(bwrap
  --clearenv
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --bind "$TMPDIR" "$TMPDIR"
  --dir "$HOME"
  "${bwrap_opts[@]}")

# A small supervisor owns the proxy and forwards termination to bubblewrap.
launch_sandbox() {
  if [[ -n "$egress_netns" && "$network" != n ]]; then
    # The unix socket is already visible inside the session through the $TMPDIR
    # bind. The prologue addresses the loopback, starts the session-side
    # listeners, and then runs bubblewrap. It is not exec'd: wrap must outlive
    # the session to close the caller-side tunnels and delete the sockets.
    unshare --user --map-root-user --net "$egress_shell" "$TMPDIR/egress-netns.sh" \
      "${bwrap_cmd[@]}" "$@"
    return $?
  elif [[ -n "$egress_netns" ]]; then
    # The same prologue, run as pasta's command: it executes in the namespace
    # pasta created, addresses the loopback there, starts the session-side
    # listeners, and then runs bubblewrap with --share-net as usual.
    "${pasta_launch[@]}" "$egress_shell" "$TMPDIR/egress-netns.sh" \
      "${bwrap_cmd[@]}" "$@"
    return $?
  fi
  exec "${pasta_launch[@]}" "${bwrap_cmd[@]}" "$@"
}
if [[ -n "$dbus_proxy_pid" || -n "$egress_netns" ]]; then
  trap 'exit 130' INT
  trap 'exit 143' TERM
  launch_sandbox "$@" <&0 &
  sandbox_pid=$!
  sandbox_status=0
  wait "$sandbox_pid" || sandbox_status=$?
  sandbox_pid=""
  exit "$sandbox_status"
else
  launch_sandbox "$@"
fi
