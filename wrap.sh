#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

bwrap_opts=()

# TODO: what should really go into that list?
env_vars=(BROWSER CLUTTER_BACKEND COLORTERM CUPS_DATADIR \
  DBUS_SESSION_BUS_ADDRESS DESKTOP_STARTUP_ID DIRENV_LOG_FORMAT DISPLAY \
  ECORE_EVAS_ENGINE EDITOR ELM_ENGINE GDK_BACKEND GIO_EXTRA_MODULES GNUPGHOME \
  GPG_TTY GREETD_SOCK GTK2_RC_FILES GTK_A11Y GTK_PATH HISTFILE HISTSIZE HOME \
  I3SOCK INFOPATH KDEDIRS KEYTIMEOUT KITTY_INSTALLATION_DIR KITTY_LISTEN_ON \
  KITTY_PID KITTY_PUBLIC_KEY KITTY_WINDOW_ID LANG LC_ADDRESS LC_IDENTIFICATION \
  NIXPKGS_ALLOW_UNFREE LC_MEASUREMENT LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER \
  LC_TELEPHONE LC_TIME LD_LIBRARY_PATH LESSKEYIN_SYSTEM LESSOPEN LIBEXEC_PATH \
  LOCALE_ARCHIVE LOCALE_ARCHIVE_2_27 LOGNAME MOZ_ENABLE_WAYLAND MOZ_PLUGIN_PATH \
  NIXOS_OZONE_WL NIXPKGS_CONFIG NIX_PATH NIX_PROFILES NIX_USER_PROFILE_DIR \
  NO_AT_BRIDGE OLDPWD PAGER PATH PWD QTWEBKIT_PLUGIN_PATH QT_PLUGIN_PATH \
  QT_QPA_PLATFORM QT_WAYLAND_DISABLE_WINDOWDECORATION QT_WAYLAND_FORCE_DPI \
  SAVEHIST SDL_VIDEODRIVER SHELL SHLVL SSH_ASKPASS SSH_AUTH_SOCK SWAYSOCK \
  TERM TERMINFO TERMINFO_DIRS TZDIR USER VDPAU_DRIVER WAYLAND_DISPLAY \
  WLR_LIBINPUT_NO_DEVICES XCURSOR_PATH XCURSOR_SIZE XCURSOR_THEME XDG_BIN_HOME \
  XDG_CACHE_HOME XDG_CONFIG_DIRS XDG_CONFIG_HOME XDG_CURRENT_DESKTOP \
  XDG_DATA_DIRS XDG_DATA_HOME XDG_DESKTOP_PORTAL_DIR XDG_RUNTIME_DIR XDG_SEAT \
  XDG_SESSION_CLASS XDG_SESSION_ID XDG_SESSION_TYPE XDG_VTNR _ \
  _JAVA_AWT_WM_NONREPARENTING __ETC_PROFILE_DONE __HM_SESS_VARS_SOURCED \
  __HM_ZSH_SESS_VARS_SOURCED __NIXOS_SET_ENVIRONMENT_DONE)

usage() {
  cat << END_OF_USAGE
__      ___ __ __ _ _ __  
\\ \\ /\\ / / '__/ _\` | '_ \\ 
 \\ V  V /| | | (_| | |_) |
  \\_/\\_/ |_|  \\__,_| .__/ 
                   |_|  

Usage: $(basename "$0") [OPTIONS] -- [bwrap args] [program to wrap with args]

OPTIONS:
  -w PATH  Write mount PATH into sandbox.
  -r PATH  Read-only mount PATH into sandbox.
  -d       Wayland display and rendering hardware access.
  -b       DBus access.
  -n       Network access.
  -a       Audio access.
  -c       Camera access.
  -u       System user information access.
  -e VAR   Add env var VAR with its current value.

OPTIONS (advanced):
  -m       Manual unsharing. By default wrap unshares ipc, net, pid, and uts 
           and tries to unshare (continue on failues) user and cgroup 
           namespaces. With this option, wrap does not automatically unshare 
           any namespaces. Use together with bwrap --unshare-* options 
           (man bwrap(1)) to unshare manually.
  -p       Do not share current working directory. By default wrap will share 
           the current working directory as a write mount and cd into it 
           before running the program. With this option, wrap will not share 
           the directory and leave the current directory untouched.
  -v       Verbose output for debugging.
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
    r)  
      bwrap_opts+=(--ro-bind "$OPTARG" "$OPTARG")
      ;;
    w)  
      bwrap_opts+=(--bind "$OPTARG" "$OPTARG")
      ;;
    c)  
      bwrap_opts+=(--dev-bind "/dev/v4l" "/dev/v4l")
      for i in /dev/video*; do
        bwrap_opts+=(--dev-bind "$i" "$i")
      done
      ;;
    b)  
      dbus_socket="$(echo "$DBUS_SESSION_BUS_ADDRESS" | cut -d= -f2)"
      bwrap_opts+=(--bind "$dbus_socket" "$dbus_socket")
      ;;
    d)  
      bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY")
      bwrap_opts+=(--dev-bind /dev/dri /dev/dri)
      bwrap_opts+=(--ro-bind /run/opengl-driver /run/opengl-driver)
      bwrap_opts+=(--ro-bind /sys/ /sys/)
      bwrap_opts+=(--ro-bind /etc/fonts /etc/fonts)
      ;;
    n)  
      bwrap_opts+=(--share-net)
      bwrap_opts+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
      bwrap_opts+=(--ro-bind /etc/ssl /etc/ssl)
      bwrap_opts+=(--ro-bind /etc/static/ssl /etc/static/ssl)
      ;;
    a)  
      bwrap_opts+=(--bind-try "$XDG_RUNTIME_DIR/pulse/native" "$XDG_RUNTIME_DIR/pulse/native")
      bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
      bwrap_opts+=(--bind "$XDG_RUNTIME_DIR/pipewire-0.lock" "$XDG_RUNTIME_DIR/pipewire-0.lock")
      ;;
    u)  
      bwrap_opts+=(--ro-bind /etc/passwd /etc/passwd)
      bwrap_opts+=(--ro-bind /etc/group /etc/group)
      ;;
    e)  
      env_vars+=("$OPTARG")
      ;;
    m)  
      unshare_all=0
      ;;
    p)  
      share_cwd=0
      ;;
    v)  
      set -x
      ;;
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
    *)
      ;;
  esac
done

# Shift off the options and optional -- off $@.
shift $((OPTIND-1))


if [[ $unshare_all -eq 1 ]]; then
  bwrap_opts+=(--unshare-all "${bwrap_opts[@]}")
fi

if [[ $share_cwd -eq 1 ]]; then
  cwd="$(pwd)"
  bwrap_opts+=(--bind "$cwd" "$cwd" )
  bwrap_opts+=(--chdir "$cwd" )
fi

OLDIFS=$IFS; IFS=" "
for p in ${NIX_PROFILES}; do
  if [[ -d "$p" ]]; then
    bwrap_opts+=(--ro-bind "$p" "$p")
  fi
done
IFS=$OLDIFS

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
  --ro-bind /bin /bin \
  --ro-bind /usr/bin /usr/bin \
  --ro-bind /nix /nix \
  --ro-bind /etc/nix /etc/nix \
  --ro-bind /etc/static/nix /etc/static/nix \
  --bind "$TMPDIR" "$TMPDIR" \
  --dir "$HOME" \
  "${bwrap_opts[@]}" \
  "$@"
