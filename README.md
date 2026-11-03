# jvm

`jvm` installs, manages and runs different JDKs on a user's system. It finds
compatible JDK builds, downloads and verifies them, keeps them in user storage
and lets you pick which one to use, either persistently or per command.

`default set <selector>`, `home`, `env` and `exec` automatically install a JDK when
no installed JDK matches the selector. Existing local matches work offline.

**The scripts are small, have no dependencies and are meant to be copied into
your Java projects.** `jvm` (Bash), `jvm.ps1` (native Windows PowerShell 5.1) and
`jvm.cmd` (Windows launcher) need no Java, no package manager and no runtime
installation step. That gives you a sure-fire way for your users to build and
run your project, even when they don't have Java installed.

On Linux and macOS, the Bash script supports Bash 3.2 and later. On Windows,
use current Git Bash, MSYS2 or Cygwin, or Windows PowerShell 5.1.

## Using it in your projects

Copy the three scripts `jvm`, `jvm.cmd` and `jvm.ps1` to the root of your
project, and add a line like this to the project's README:

```sh
./jvm x 25+ your_command
```

This runs `your_command` with a matching JDK (Java 25 or newer), downloading
and installing Temurin if no installed JDK matches. Use `.\jvm.cmd` on Windows
outside Bash.

Or you can configure your PATH and JAVA_HOME for the duration of your shell session
by running:

```sh
eval $(./jvm env 25+)
```

(You can run plain `./jvm env` if you need a reminder on how to use it with `eval`)

To avoid repeating the JDK version in every command, add a `.jvmrc` file to the
project root (see [Configuration](#configuration)):

```
java=25+
```

At which point the previous command can be simplified to:

```sh
eval $(./jvm env)
```



## Neat Trick (Runnable .java files)

Take a look at the [hello.java](./hello.java) file, it has this strange line at
the top of the file which, on Linux and Mac, tells your shell how to run the code.

```java
///usr/bin/env ./jvm x 25+ java "$0" "$@" ; exit $?
void main() {
    IO.println("Hello, World!");
}
```

And then you simply run it like:

```sh
./hello.java
```

(PS: don't forget to make the file executable first with `chmod +x hello.java`)



Now, you could already do this without `jvm`, but the nice thing is that now it
will even work for people who don't have Java installed. And it will even make
sure it's the correct version!

## Using it installed

Copy the scripts to a directory on your `PATH`, for example `~/.local/bin`:

```sh
mkdir -p ~/.local/bin
cp jvm jvm.cmd jvm.ps1 ~/.local/bin/
chmod +x ~/.local/bin/jvm
```

On Windows you will probably need to add that directory (for example
`%USERPROFILE%\.local\bin`) to your `PATH` yourself.

To make the default JDK available in every shell, add this once to your shell
profile:

```sh
# Unix
export JAVA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/default"
export PATH="$JAVA_HOME/bin:$PATH"

# Git Bash / Cygwin / MSYS2
export JAVA_HOME="$(cygpath -m "${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/default")"
export PATH="$(cygpath -u "${JAVA_HOME}")/bin:$PATH"
```

## Usage

```
jvm <command> [options] [selector]
```

| Command | Purpose |
| --- | --- |
| `available`, `a [-t] [selector]` | Show compatible JDKs available to download |
| `install`, `i [-d] [-v] [selector]` | Download, verify and install a JDK (`-d` selects the global default; `-v` selects its major default) |
| `uninstall`, `u <selector>` | Remove an installed JDK |
| `list`, `l [selector]` | Show installed JDKs, even offline |
| `default [<major>]`, `d [<major>]` | Query the global or per-major default offline |
| `default set [<major>] <selector>`, `d set [<major>] <selector>` | Set the global or per-major default, installing if needed |
| `home`, `h [selector]` | Print the selected JDK home, installing if needed |
| `env`, `e [-f] [selector]` | Print shell exports for the selected JDK, installing if needed |
| `exec`, `x <selector> [--] <command> [args...]` | Run a command with the selected JDK, installing if needed |

`exec` and `x` require a selector. Use `_` to resolve project `java`, then user
`java`, then the global default, then Java 25. Configuration errors, failed
configured selections and unusable defaults are errors. The `_` placeholder is
exclusive to exec; it is not a configuration value. Other commands give it no
placeholder meaning and retain their existing exact-directory ID rules.
`home` and `env` use the same precedence when their selector is omitted.
`jvm default` queries the global default; `jvm default 21` queries Java 21.
After `set`, one argument is a selector (`jvm default set 21` sets the global
default using selector `21`); two arguments are a scope major and selector
(`jvm default set 21 temurin-21` sets the Java 21 default). A scope is a positive
integer without leading zeros, and the selected JDK must match that major.
Queries never install. The `d` alias uses the same grammar.

One optional `--` immediately after the exec selector is skipped. The command
must be nonempty; it and every later argument are forwarded unchanged.

Selectors are a major (`21`), a distro (`temurin`, for `available`/`list`), a
distro-major (`temurin-21`) or a full installed ID. Ranges such as `21+`,
`21..26` and `temurin-21+` are also accepted, except for `uninstall`.

Examples:

```sh
jvm available temurin              # what can be installed
jvm install                        # install the default JDK (Temurin 25)
jvm i -d temurin-21                # install Temurin 21 and make it the default
jvm i -v temurin-25                # install Temurin 25 and select its major default
jvm i -d -v temurin-25             # select both defaults (major first, then global)
jvm list                           # what is installed
jvm default set 21 temurin-21      # set the default for Java 21
jvm home 21                        # print JDK 21's home, installing if needed
eval "$(jvm env temurin-21)"       # use Temurin 21 in the current shell
jvm x 21..26 java -version         # run with the highest matching JDK
jvm x _ java -version              # use configuration/default selection
jvm uninstall temurin-21
```

### Configuration

Optional `key=value` lines, read from `./.jvmrc` and then
`$XDG_CONFIG_HOME/jvm/config` (or `~/.config/jvm/config`):

- `java=21+` selects the Java major or range.
- `distro=graalvm-community` selects the distribution.

A command-line selector overrides the project file, which overrides the user
file. Configuration does not affect `default`, `available`, `list`, `uninstall`
or help. Run `jvm --help` for the full reference, and see [SPEC.md](SPEC.md) for
the detailed behavior.
