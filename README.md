# Nixwrap - Easy Application Sandboxing

<p align="center"><img src="./wrap.jpg" alt="A cute wrap, the mascot of Nixwrap" style="width:400px;"/></p>

Nixwrap is a command line utility to easily wrap a processes in a sandbox preventing them from accessing your system. Nixwrap can hinder access to environment variables, files, devices and the network. Under the hood, Nixwrap is based on [Bubblewrap](https://github.com/containers/bubblewrap) which in turn uses [Linux Namespaces](https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html).

The goal of Nixwrap is to make sandboxing easy to use for common use cases, reducing the barrier to entry. While it will not provide perfect protection against any untrusted code, it does add protection for simple common threads.

## Examples

### npm install

> You need to run `npm install` on a project, but you cannot not trust all its dependencies.

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

## Usage
### Command line utility
The wrap command allows you to sandbox applications ad-hoc with a simple and intuitive interface. With wrap, you can create a secure environment on the fly for a single instance of an application run, without the need for persistent configurations or changes to the system. This is particularly useful for testing, running untrusted software, or limiting access to system resources.

#### General syntax:
`wrap [OPTIONS] -- [bwrap args] [program to wrap with args]`

#### Options
```
 -w PATH  Write mount PATH into the sandbox.
 -r PATH  Read-only mount PATH into the sandbox.
 -d       Wayland display and rendering hardware access.
 -n       Network access.
 -a       Audio access.
 -c       Camera access.
 -b       DBus access.
 -u       System user information access.
 -e VAR   Add env var VAR with its current value.
```

#### Advanced Options
```
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
```

### NixOS Utility
This extends the convenience of `wrap` by offering a Nix function that wraps packages to always run in a sandbox environment. 

#### Flake
Add the Nixwrap flake as an input in your NixOS system flake.

```nix
{
  inputs = {
    # ...

    wrap.url = "github:rti/nixwrap";
    wrap.inputs.nixpkgs.follows = "nixpkgs";
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

```nix
(pkgs, inputs, ...):
{
    /* wrap node with network access */
    environment.systemPackages = [ 
        (inputs.wrap.packages.wrap {
            package = pkgs.nodejs;
            executable = "node";
            wrapArgs = "-n";
        })
    ];
}
```

## Supported platforms
It is tested exclusively on NixOS, even though the concept should work in any distribution that ships a current kernel.

## License
`wrap` is licensed under the MIT License. See the LICENSE file for more details.
