# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that Ghostty
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or [ghostty.org](https://ghostty.org/docs)

## Implementation Details

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/ghostty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/ghostty.bash`.
This also works for older versions of Bash.

```bash
# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Elvish

For [Elvish](https://elv.sh), `$GHOSTTY_RESOURCES_DIR/src/shell-integration`
contains an `./elvish/lib/ghostty-integration.elv` file.

Elvish, on startup, searches for paths defined in `XDG_DATA_DIRS`
variable for `./elvish/lib/*.elv` files and imports them. They are thus
made available for use as modules by way of `use <filename>`.

Ghostty launches Elvish, passing the environment with `XDG_DATA_DIRS` prepended
with `$GHOSTTY_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/ghostty-integration.elv`. The user can then import it
by `use ghostty-integration` every time after shell startup or
autostart integration in `$XDG_CONFIG_HOME/elvish/rc.elv`,
which will run the integration routines.

If you decide to autostart `ghostty-integration` with `rc.elv`, you should
detect whether the terminal is Ghostty or not. To do this, add this to the end
of your `rc.elv` file:

```elvish
if (eq $E:TERM "xterm-ghostty") {
  try { use ghostty-integration } catch { }
}
```

### Fish

For [Fish](https://fishshell.com/), Ghostty prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Nushell

For [Nushell](https://www.nushell.sh/), Ghostty prepends to the
`XDG_DATA_DIRS` directory, making the `ghostty` module available through
Nushell's vendor autoload mechanism. Ghostty then automatically imports
the module using the `-e "use ghostty *"` flag when starting Nushell.

Nushell provides many shell features itself, such as `title` and `cursor`,
so our integration focuses on Ghostty-specific features like `sudo`,
`ssh-env`, and `ssh-terminfo`.

The shell integration is automatically enabled when running Nushell in Ghostty,
but you can also load it manually if shell integration is disabled.

Note that Nushell doesn't allow sourcing not _parse-time constants_,
so `GHOSTTY_RESOURCES_DIR` environment variable cannot be used.

Here is an example of `config.nu` with default `GHOSTTY_RESOURCES_DIR` for macOS:

```nushell
source /Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu
use ghostty *
```

### PowerShell

Automatic [PowerShell](https://learn.microsoft.com/powershell/) integration
works for `pwsh` (PowerShell 7) and, on Windows, `powershell` (Windows
PowerShell 5.1). PowerShell has no environment variable or directory that
points it at a startup file, so Ghostty appends `-NoExit -Command` and a
loader to the command. The loader runs after the user's profile. It reads
`powershell/ghostty.ps1` as text and runs it in the global scope, so the
execution policy, which governs script files, does not stop it; if it fails,
it prints one line to stderr and the shell carries on without it.

Only a command whose arguments all leave PowerShell interactive gains the
loader: `-NoLogo`, `-NoProfile`, `-Login`, `-ExecutionPolicy`,
`-WorkingDirectory` and a few more (`setupPowerShell` in
`src/termio/shell_integration.zig`). A command that runs something, such as
`pwsh -Command ...` or `pwsh script.ps1`, is left alone.

The script wraps the `prompt` function and, when PSReadLine is loaded,
PSReadLine's `PSConsoleHostReadLine`, which marks where a command's output
starts. Without PSReadLine (removed, or not loaded because a screen reader
is in use) nothing can mark that, so the prompt ends with `133;I` and the
input ends at the end of its line. Unless the user has set their own,
the script sets PSReadLine's `PromptText` to the last visible characters of
the prompt: with our marks in the prompt string, PSReadLine finds none
itself, and the prompt no longer turns red while the input does not parse.
Of the features, `cursor`, `path` and `title` are supported; `sudo`,
`ssh-env` and `ssh-terminfo` are not.

With `-Command`, PowerShell prints no startup banner. A prompt function
defined after the script has loaded, such as one from `oh-my-posh init pwsh`
or `Import-Module posh-git` typed at the prompt, replaces the script's, and
the prompts lose their marks; set it up in the profile instead. Prompt
frameworks that write their own OSC 133 marks have not been tried with the
script: both sets of marks would reach the terminal.

To load it manually, at the end of the profile:

```powershell
# Ghostty shell integration for PowerShell. This must be at the end of your profile!
if ($env:GHOSTTY_RESOURCES_DIR) {
  . ([scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine(
    $env:GHOSTTY_RESOURCES_DIR, 'shell-integration', 'powershell', 'ghostty.ps1'))))
}
```

### Zsh

Automatic [Zsh](https://www.zsh.org/) integration works by temporarily setting
`ZDOTDIR` to our `zsh` directory. An existing `ZDOTDIR` environment variable
value will be retained and restored after our shell integration scripts are
run.

However, if `ZDOTDIR` is set in a system-wide file like `/etc/zshenv`, it will
override Ghostty's `ZDOTDIR` value, preventing the shell integration from being
loaded. In this case, the shell integration needs to be loaded manually.

To load the Zsh shell integration manually:

```zsh
if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
  source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
fi
```

Shell integration requires Zsh 5.1+.
