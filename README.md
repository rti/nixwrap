# Nixwrap - Easy Application Sandboxing

<p align="center"><img src="./wrap.jpg" alt="A cute wrap, the mascot of Nixwrap" style="width:400px;"/></p>

Nixwrap is a command-line utility and NixOS utility function to make the process of sandboxing applications simple and straightforward. With Nixwrap, you can easily isolate applications from the rest of your system, controlling their access to the filesystem, devices, and network, enhancing your system's security and privacy. `wrap` serves as a frontend to `bwrap` [Bubblewrap](https://github.com/containers/bubblewrap), integrating its functionalities with additional options to enhance the user experience.

## Features
- Easy-to-use command-line interface.
- Flexible mounting options for filesystem control.
- Current working directory shared by default, can be disabled.
- Options for granting access to Wayland display, DBus, network, audio, and camera.
- Ability to restrict applications to read-only file access.
- Environment variable control within the sandbox.
- Advanced manual unsharing of namespaces for expert users.
- Option to maintain or prevent sharing of the current working directory.
- Verbose output mode for debugging.

## Examples

Run `npm install` with write access to the current working directory and network access.
```shell
wrap -n npm install
```

Run a random python script with Pulse Audio and Pipewire access, but not sharing the current working directory.
```shell
wrap -p -a python my-tool.py
```

Run `qutebrowser` with network access, read access to its config, and write access to its data and cache dir.
```shell
wrap -n -r ~/.config/qutebrowser -w ~/.local/share/qutebrowser -w ~/.cache/qutebrowser qutebrowser
```

## Usage
### Command line utility
The wrap command allows you to sandbox applications ad-hoc with a simple and intuitive interface. With wrap, you can create a secure environment on the fly for a single instance of an application run, without the need for persistent configurations or changes to the system. This is particularly useful for testing, running untrusted software, or limiting access to system resources.

#### General syntax:
`wrap [OPTIONS] -- [bwrap args] [program to wrap with args]`

#### Options
```
 -w PATH    Write mount PATH into the sandbox.
 -r PATH    Read-only mount PATH into the sandbox.
 -d         Wayland display and rendering hardware access.
 -n         Network access.
 -a         Audio access.
 -c         Camera access.
 -b         DBus access.
 -u         System user information access.
 -e VAR     Add env var VAR with its current value.
```

#### Advanced Options
```
 -m         Manual unsharing. Does not automatically unshare any namespaces.
 -p         Do not share the current working directory.
 -v         Verbose output for debugging.
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

## License
`wrap` is licensed under the MIT License. See the LICENSE file for more details.
