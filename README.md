# Nixwrap - Easy Application Sandboxing on NixOS

<p align="center"><img src="./wrap.png" alt="A cute wrap, the mascot of Nixwrap" style="width:400px;"/></p>

Nixwrap is a command line utility and Nix function to easily wrap processes in a sandbox preventing them from accessing your system. Nixwrap can hinder access to environment variables, file system, devices and network. Under the hood, Nixwrap is based on [Bubblewrap](https://github.com/containers/bubblewrap) and [pasta](https://passt.top/passt/about/).

The goal of Nixwrap is to make sandboxing easy to use for common use cases. While it will not provide perfect protection against any untrusted code, it does add protection for common threats.

> [!NOTE] 
> Nixwrap does not have a stable interface yet. While I try to prevent breaking changes, I will prioritize refactoring for cleanness over compatibility for now.

## Examples

### Imperative npm install

> You need to run `npm install` on a project, but you cannot trust all its dependencies.

To run `npm install` only with write access to the current working directory and network access, simply do:

```shell
wrap -n npm install
```

### Imperative GUI Application using nix3-run

> You need to run a GUI application, but you want to limit access to your filesystem and environment variables.

To run vscodium using `nix3-run` with network and display access, only writing to `$HOME/some-dir`:

```shell
wrap -n -d -p -w $HOME/some-dir nix run nixpkgs#vscodium
```

### Imperative Python tool

> You need to run a `python` script that has access to your audio hardware.

Run a python script with Pulse Audio and Pipewire access, but not sharing the current working directory:

```shell
wrap -a -p python my-tool.py
```

### Imperative single-endpoint egress from an offline sandbox

> You need to run a tool that talks to one known server — for example a coding agent reaching only its model endpoint — but the tool must not be able to reach anything else, not even your own machine.

`--allowed-egress-tcp` and `--allowed-egress-udp` keep the sandbox network-less and tunnel exactly one `domain:port` each to the caller's network:

```shell
wrap -u --allowed-egress-tcp strata.netpleb.com:443 curl https://strata.netpleb.com
```

The domain is resolved by the caller before the sandbox starts. Inside the session the name resolves to that address through a generated `/etc/hosts`, the address is assigned to the session's own `lo` interface, and connections to it are relayed through a unix socket in wrap's private directory, which is destroyed when the session closes. Nothing else is reachable: no other address, no other port, and no DNS. It requires neither `-n` nor root, and no firewall rules are installed anywhere; unreachability is structural. (A kernel firewall cannot do this job at the pasta boundary anyway: pasta is a userspace relay, so sandbox traffic only ever exists in the kernel as caller-owned sockets that a host ruleset could not single out.)

An IPv4 address may be given instead of a name (`--allowed-egress-tcp 203.0.113.7:443`), in which case no name is resolved and no `/etc/hosts` is written; the address still becomes local to the session. IPv6 is not supported. UDP datagram boundaries are preserved, so a datagram endpoint works as the application expects; TCP and UDP on the same port are separate allowances.

As with `-n` and `-N`, the caller's certificate authorities are shared into the session, so an HTTPS endpoint verifies normally. The session also runs with the caller's own uid and gid, as `-n` does: `-u` reports your username, and files the session writes are yours.

With `-n` or `-I` the tunnels also work: the endpoint stays host-resolved and reachable through its own path, next to pasta's ordinary, unrestricted egress through `wrap0`. The allowlist then adds ways out; it does not confine pasta (nothing rootless can — see the note on why no firewall is involved above), so a confined session should not ask for `-n`. wrap says so on stderr when the two are combined. `-N` is rejected outright: the session would share the caller's namespace, whose loopback wrap cannot address.
### Declarative Opencode

> You want to run your opencode agent with access to the current working directory.

Use `wrap.lib.${system}.mkWrap` to build a wrapped launcher, allow current working directory access, opencode config and cache directory access as well as network access.

```nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.wrap.url = "github:rti/nixwrap";

  outputs = { nixpkgs, flake-utils, wrap, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = wrap.lib.${system}.mkWrap {
          name = "opencode";
          package = pkgs.opencode;
          shareCwd = true;
          capabilities.network = true;
          mounts = {
            readOnly = [ "~/.config/opencode" ];
            writable = [ "~/.local/share/opencode" ];
          };
        };
      });
}
```

From the project directory, run:

```sh
nix run .
```

## How to use imperatively

By default, the imperative `wrap` command will:

- ✅ Prevent network access. (Use `-n` to allow, or `--allowed-egress-tcp`/`--allowed-egress-udp` for a single endpoint.)
- ✅ Prevent access to Wayland and X. (Use `-d` (desktop) to allow.)
- ✅ Prevent camera access. (Use `-c` to allow.)
- ✅ Prevent audio access. (Use `-a` to allow.)
- ✅ Prevent D-Bus socket access. (Use filtered rules below, or `-B` for direct, unfiltered session-bus access.)
- ✅ Prevent access to user name information. (Use `-u` to allow.)
- ❗ **Allow write access** to the **current working directory**. (Use `-p` to prevent.)
- ❗ **Allow** read only access to all paths in `$NIX_PROFILES`.
- ❗ **Allow** read only access to the full Nix store and Nix configuration. (Use `-s` to share selected closures instead.)
- ❗ **Allow** read only access to [common bin and lib paths](https://github.com/rti/nixwrap/blob/main/wrap.sh#L97).
- ❗ **Allow** access to a set of [common environment variables](https://github.com/rti/nixwrap/blob/main/wrap.sh#L9).

### General syntax:

`wrap [OPTIONS] [-- BWRAP_ARGS] PROGRAM_TO_WRAP_WITH_ARGS`

### Options

```
  -d       Allow Desktop access, Wayland, X11, and rendering hardware.
  -n       Allow Network access, without sharing host loopback or abstract sockets.
  -P PORT  With -n, allow TCP access to this host loopback port; repeatable.
  -N       Keep the caller's network, including loopback and abstract sockets.
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
           In the default network-less mode it is the sandbox's only way out;
           with -n or -I it adds a host-resolved path next to pasta's
           egress. Alias: --allow. IPv4 only.
  --allowed-egress-udp DOMAIN:PORT | ADDRESS:PORT
           Same as --allowed-egress-tcp for one UDP endpoint. Alias: --allow-udp.
  -v       Verbose output for debugging.
```

### Advanced Options

```
  -p       Do not implicitly mount the current working directory writable.
           Takes precedence over -f. The launch directory is preserved if it
           exists inside the sandbox; otherwise bubblewrap falls back to HOME.
  -f       **DEPRECATED** Will be removed in the future, use -w or -r.
           Force share current working directory. By default wrap will share
           the current working directory as a write mount and cd into it only
           if it is not the caller's home and does not match these patterns:
           ^/$, ^/home$, ^/boot, ^/etc, ^/proc, ^/run, ^/sys, ^/var
           This option bypasses that check, but does not override -p.
```

### Filesystem mounts

Path mounts are applied in this order; later mounts take precedence:

1. General paths such as `/bin` and `/nix`, read-only.
2. Persistent storage (`-H`) at the caller's unchanged `$HOME`.
3. The writable working directory, when implicit sharing is enabled and allowed.
4. `$NIX_PROFILES`, read-only, after home/cwd mounts so they cannot hide host profiles.
5. Explicit `-r` and `-w` mounts, in argument order, at their original host paths.

Explicit mounts have the final say: `-r "$PWD"` overrides implicit writable cwd
sharing, and `-w` can override a default read-only runtime/profile mount.
Writable parent mounts can also hide earlier read-only mounts beneath them.

## How to use declaratively

The `lib.mkWrap` function takes the following arguments.

| Argument | Description |
| --- | --- |
| `name` | Name of the generated launcher. Required. |
| `package` | Package containing the executable. Required. |
| `executable` | Executable under the package's `bin` directory. Defaults to `package.pname`. |
| `arguments` | Fixed arguments before those supplied at launch. Defaults to `[]`. |
| `home` | Host backing directory to create if needed and mount writable at the caller's HOME inside the sandbox. The HOME value does not change. Omit to keep the default isolated home. |
| `shareCwd` | Mount the launch-time working directory writable, subject to wrap's protected-path rules. Defaults to `false`. Startup preserves the cwd if it exists inside the sandbox, otherwise falling back to HOME. |
| `hostPorts` | Host loopback TCP ports accessible at the same `127.0.0.1` port inside the sandbox. Defaults to `[]`. Requires `capabilities.network = true` and `hostNetwork` disabled. |
| `closures` | Optional list of additional Nix packages/store paths to share with their runtime closures. Omit or set `null` to share all of `/nix` (default). Any list, including `[]`, enables closure-only sharing and automatically includes `package`; `$NIX_PROFILES` are not auto-mounted. |
| `mounts.readOnly` | Host paths to mount read-only. Defaults to `[]`. |
| `mounts.writable` | Host paths to mount writable. Defaults to `[]`. |
| `capabilities` | Boolean attributes: `network`, `hostNetwork`, `desktop`, `audio`, `camera`, `hostDbus`, `userInfo`. All default to disabled. `network` selects isolated pasta networking (`-n`); `hostNetwork` retains the caller's network (`-N`) and takes precedence over `network`. `hostDbus` grants direct, unfiltered host session D-Bus access (`-B`), without starting a proxy. |
| `dbus` | Filtered session-bus policy: lists `call`, `broadcast`, `talk`, `own`, `see`. All default to `[]`. Cannot be combined with `capabilities.hostDbus = true` (unfiltered access). See below. |
| `environment` | Attribute set of variables: a value sets the variable; `null` passes through the caller's value. Defaults to `{}`. Set `home`, not `environment.HOME`, to select persistent home storage. |


Paths in `home`, `mounts.readOnly`, and `mounts.writable` may begin with `~/`; the launcher resolves that prefix against the caller's `HOME` at runtime. The rest of the path stays literal: shell variables, globs, and commands are not expanded.

## Supported platforms

Nixwrap is at the moment tested exclusively on NixOS, even though the concept should work in any distribution that ships a current kernel.

## Installation

You need [NixOS](https://nixos.org/download/) with the `nix-command` and `flakes` [experimental features enabled](https://nix.dev/manual/nix/stable/command-ref/conf-file.html#conf-experimental-features).

### Run without installing

```shell
nix run github:rti/nixwrap -- echo "Hello from the sandbox"
```

Get usage help:

```shell
nix run github:rti/nixwrap -- -h

```

### Add to a flake-based NixOS system

Add the `nixwrap` input to your system's `flake.nix` and include its package in `environment.systemPackages`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixwrap.url = "github:rti/nixwrap";
    nixwrap.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nixwrap, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ({ pkgs, ... }: {
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          environment.systemPackages = [
            nixwrap.packages.${pkgs.stdenv.hostPlatform.system}.default
          ];
        })
      ];
    };
  };
}
```

The `wrap` command is then available system-wide.

## License

`wrap` is licensed under the MIT License. See the LICENSE file for more details.

## Similar projects

- https://git.sr.ht/~fgaz/nix-bubblewrap
- https://github.com/Frontear/nix-wrap
- https://codeberg.org/decentstates/nix-housing
