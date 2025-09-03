# Nixwrap - Easy Application Sandboxing on NixOS

<p align="center"><img src="./wrap.png" alt="A cute wrap, the mascot of Nixwrap" style="width:400px;"/></p>

Nixwrap is a command line utility to easily wrap processes in a sandbox preventing them from accessing your system. Nixwrap can hinder access to environment variables, files, devices and the network. Under the hood, Nixwrap is based on [Bubblewrap](https://github.com/containers/bubblewrap) which in turn uses [Linux Namespaces](https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html).

The goal of Nixwrap is to make sandboxing easy to use for common use cases, reducing the barrier to entry. While it will not provide perfect protection against any untrusted code, it does add protection for simple common threads.

## Examples

### npm install

> You need to run `npm install` on a project, but you cannot trust all its dependencies.

To run `npm install` only with write access to the current working directory and network access, simply do:
```shell
wrap -n npm install
```

### GUI Application using nix3-run

> You need to run a GUI application, but you want limit access to your filesystem.

To run software using `nix3-run`, in this case vscodium with network and display access, without access to your home directory:
```shell
wrap -n -d -p nix run nixpkgs#vscodium
```

### Python tool

> You need to run a `python` script that has access to your audio hardware.

Run a python script with Pulse Audio and Pipewire access, but not sharing the current working directory:
```shell
wrap -a -p python my-tool.py
```

## How to use

By default, Nixwrap will:
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

#### General syntax:
`wrap [OPTIONS] [-- BWRAP_ARGS] PROGRAM_TO_WRAP_WITH_ARGS`

#### Options
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
  -v       Verbose output for debugging.
```

#### Advanced Options
```
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
           and tries to unshare (continue on failues) user and cgroup 
           namespaces. With this option, wrap does not automatically unshare 
           any namespaces. Use together with bwrap --unshare-* options 
           (man bwrap(1)) to unshare manually.
```

### Wrap binaries via Nix

#### Flake
Add the Nixwrap flake as an input in your flake.

```nix
{
  inputs = {
    wrap.url = "github:rti/nixwrap";
  };

  # outputs ...
}
```

#### Wrap a package
To wrap a package, use the function from `inputs.wrap.lib.wrap`. It takes the following arguments:
- `package` The package to wrap.
- `executable` The name of the executable, optional, defaults to package name.
- `wrapArgs` Arguments to wrap, see above.

The function returns a new package wrapping the given package.

E.g. to wrap `nodejs` with access to current working directory (default) and additional network access, do:

```nix
inputs.wrap.packages.wrap {
  package = pkgs.nodejs;
  executable = "node";
  wrapArgs = "-n";
}
```

#### Flake devShell with wrapped `nodejs`

This example installs `nodejs` in a devShell, but wraps `node` with Nixwrap, so what it can only access the current working directory and the network.

```nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.wrap.url = "github:rti/nixwrap";

  outputs = { nixpkgs, wrap, ... } @inputs:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {

        devShells.default = pkgs.mkShell {
          buildInputs = [
            (wrap.lib.${system}.wrap {
              package = pkgs.nodejs;
              executable = "node";
              wrapArgs = "-n";
            })
          ];
        };
      }
    );
}
```

## Supported platforms
Nixwrap is at the moment tested exclusively on NixOS, even though the concept should work in any distribution that ships a current kernel.

## License
`wrap` is licensed under the MIT License. See the LICENSE file for more details.
