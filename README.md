# Nixwrap - Easy Application Sandboxing on NixOS

<p align="center"><img src="./wrap.png" alt="A cute wrap, the mascot of Nixwrap" style="width:400px;"/></p>

Nixwrap is a command line utility to easily wrap processes in a sandbox preventing them from accessing your system. Nixwrap can hinder access to environment variables, files, devices and the network. Under the hood, Nixwrap is based on [Bubblewrap](https://github.com/containers/bubblewrap) which in turn uses [Linux Namespaces](https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html).

The goal of Nixwrap is to make sandboxing easy to use for common use cases, reducing the barrier to entry. While it will not provide perfect protection against any untrusted code, it does add protection for simple common threats.

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

- ✅ Prevent network access. (Use `-n` to allow.)
- ✅ Prevent access to Wayland and X. (Use `-d` (desktop) to allow.)
- ✅ Prevent camera access. (Use `-c` to allow.)
- ✅ Prevent audio access. (Use `-a` to allow.)
- ✅ Prevent DBus socket access. (Use `-b` to allow.)
- ✅ Prevent access to user name information. (Use `-u` to allow.)
- ❗ **Allow write access** to the **current working directory**. (Use `-p` to prevent.)
- ❗ **Allow** read only access to all paths in `$NIX_PROFILES`.
- ❗ **Allow** read only access to [nix store and config paths](https://github.com/rti/nixwrap/blob/main/wrap.sh#L92).
- ❗ **Allow** read only access to [common bin and lib paths](https://github.com/rti/nixwrap/blob/main/wrap.sh#L97).
- ❗ **Allow** access to a set of [common environment variables](https://github.com/rti/nixwrap/blob/main/wrap.sh#L9).

### General syntax:

`wrap [OPTIONS] [-- BWRAP_ARGS] PROGRAM_TO_WRAP_WITH_ARGS`

### Options

```
  -d       Allow Desktop access, Wayland, X11, and rendering hardware.
  -n       Allow Network access.
  -a       Allow Audio access.
  -c       Allow Camera access.
  -b       Allow DBus access.
  -u       Allow System user information access.
  -e VAR   Allow env var VAR access.
  -r PATH  Mount PATH into sandbox in read-only mode.
  -w PATH  Mount PATH into sandbox in read write mode.
  -H PATH  Use PATH as persistent home storage, mounted writable at the caller's HOME.
  -v       Verbose output for debugging.
```

### Advanced Options

```
  -p       Do not implicitly mount the current working directory writable.
           Takes precedence over -f. The launch directory is preserved if it
           exists inside the sandbox; otherwise bubblewrap falls back to HOME.
  -f       Force share current working directory. By default wrap will share
           the current working directory as a write mount and cd into it only
           if it is not the caller's home and does not match these patterns:
           ^/$, ^/home$, ^/boot, ^/etc, ^/proc, ^/run, ^/sys, ^/var
           This option bypasses that check, but does not override -p.
  -m       Manual unsharing. By default wrap unshares ipc, net, pid, and uts
           and tries to unshare (continue on failues) user and cgroup
           namespaces. With this option, wrap does not automatically unshare
           any namespaces. Use together with bwrap --unshare-* options
           (man bwrap(1)) to unshare manually.
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
| `mounts.readOnly` | Host paths to mount read-only. Defaults to `[]`. |
| `mounts.writable` | Host paths to mount writable. Defaults to `[]`. |
| `capabilities` | Boolean attributes: `network`, `desktop`, `audio`, `camera`, `dbus`, `userInfo`. All default to disabled. |
| `environment` | Attribute set of variables: a value sets the variable; `null` passes through the caller's value. Defaults to `{}`. Set `home`, not `environment.HOME`, to select persistent home storage. |


Paths in `home`, `mounts.readOnly`, and `mounts.writable` may begin with `~/`; the launcher resolves that prefix against the caller's `HOME` at runtime. The rest of the path stays literal: shell variables, globs, and commands are not expanded.

## Supported platforms

Nixwrap is at the moment tested exclusively on NixOS, even though the concept should work in any distribution that ships a current kernel.

## License

`wrap` is licensed under the MIT License. See the LICENSE file for more details.

## Similar projects

- https://git.sr.ht/~fgaz/nix-bubblewrap
- https://github.com/Frontear/nix-wrap
- https://codeberg.org/decentstates/nix-housing
