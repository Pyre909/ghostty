# Ghostty shell integration for PowerShell: pwsh 7 on any platform, and
# Windows PowerShell 5.1.
#
# Ghostty starts PowerShell with -NoExit -Command and a loader that reads
# this file as text and runs it in the global scope, after the user's
# profile (src/termio/shell_integration.zig). Reading it as text, rather
# than dot-sourcing it, keeps the execution policy out of the way. It can
# also be loaded by hand as the last thing in a profile (see ../README.md).
#
# It wraps the prompt function, and PSReadLine's PSConsoleHostReadLine when
# PSReadLine is loaded:
#
#   133;D;<code>  the exit status of the command accepted at the last prompt
#   133;A         the start of the prompt (redraw=0: PowerShell does not
#                 redraw its prompt on a resize)
#   OSC 9;9/7     the working directory, when it changed: ConEmu's OSC 9;9
#                 on Windows, a kitty-shell-cwd OSC 7 elsewhere
#   133;B         the end of the prompt, with PSReadLine
#   133;I         the same without PSReadLine: input ends at the end of the
#                 line, as nothing marks where the output starts
#   133;C         the start of the output, once PSReadLine has accepted a
#                 command line and written its CR LF
#
# This script aims to be written so that it can't really fail: it runs
# under any strict mode or $ErrorActionPreference the profile sets, and a
# failure leaves the shell working with the user's own prompt.

# Only in a console, and only once.
if ($Host.Name -ne 'ConsoleHost' -or
    (Get-Variable -Name __GhosttyState -Scope Global -ErrorAction Ignore)) {
  return
}

# The setup runs in a child scope so that its variables and strict mode
# stay out of the user's global scope; what it keeps is the global state
# below and the two global functions.
& {
  Set-StrictMode -Off
  $features = @("$env:GHOSTTY_SHELL_FEATURES" -split ',')
  $windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

  $s = @{
    # The user's prompt, run inside ours. PowerShell always defines one,
    # but a profile can remove it.
    Prompt = $function:prompt
    # PSReadLine's PSConsoleHostReadLine, or $null without PSReadLine.
    ReadLine = $null
    # Whether a command was accepted since the last prompt (PSReadLine),
    # and the last history id the prompt saw (without PSReadLine): -1
    # before the first prompt, which follows the line that loaded us
    # rather than a command.
    Running = $false
    HistoryId = -1
    # $LASTEXITCODE and the newest error record when the last command
    # started, to tell a native program's exit code from a cmdlet's error.
    ExitCode = $null
    Error = $null
    # The last directory reported.
    Cwd = $null
    # The PromptText we last gave PSReadLine: '' before the first, $null
    # when the user set their own and we leave it alone.
    PromptText = $null
    Windows = $windows
    HostName = ''
    Title = $features -contains 'title'
    # DECSCUSR's bar at the prompt (5 blinks, 6 does not), or $null.
    Cursor = $null
    CursorSet = $false
  }
  if ($features -contains 'cursor:steady') {
    $s.Cursor = 6
  } elseif ($features -contains 'cursor:blink') {
    $s.Cursor = 5
  }
  if (-not $windows) {
    try {
      $s.HostName = [System.Net.Dns]::GetHostName() -replace '[\x00-\x1f\x7f]', ''
    } catch {}
  }
  # PSReadLine draws the prompt's last characters again, in its error
  # colour, while the input does not parse. Unless told which characters
  # with -PromptText, it works them out from the prompt, and with our
  # sequences in the prompt string it finds none: its PromptText stays
  # empty ('> ' without us) and the prompt no longer turns red. So we give
  # it the end of the user's own prompt on every prompt, until we find
  # PromptText is not what we last gave it: the user set their own,
  # before or after this.
  if (Test-Path Function:\PSConsoleHostReadLine) {
    $s.ReadLine = $function:PSConsoleHostReadLine
    $s.PromptText = ''
  }

  # GHOSTTY_BIN_DIR is on PATH when the shell starts (Exec); a profile
  # that sets PATH can drop it.
  if ($features -contains 'path' -and $env:GHOSTTY_BIN_DIR) {
    $sep = [IO.Path]::PathSeparator
    $parts = @("$env:PATH" -split [regex]::Escape($sep))
    $missing = if ($windows) {
      $parts -notcontains $env:GHOSTTY_BIN_DIR
    } else {
      $parts -cnotcontains $env:GHOSTTY_BIN_DIR
    }
    if ($missing) {
      if ($env:PATH) {
        $env:PATH = "$env:PATH$sep$env:GHOSTTY_BIN_DIR"
      } else {
        $env:PATH = $env:GHOSTTY_BIN_DIR
      }
    }
  }

  # Read-only, so that a profile's clean-up with Remove-Variable * leaves
  # it; what the hashtable holds still changes.
  Set-Variable -Name __GhosttyState -Value $s -Scope Global -Option ReadOnly

  function global:prompt {
    # Every statement changes $?, so it is read first. The prompt does not
    # set StrictMode -Off, which the user's prompt would inherit: what it
    # reads may be unset (LASTEXITCODE before any native program ran) and
    # is read so that strict mode allows it.
    $ok = $global:?
    $s = $global:__GhosttyState
    $code = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore
    $err = if ($global:Error.Count) { $global:Error[0] } else { $null }
    $e = [char]27
    $bel = [char]7
    $pre = ''

    try {
      $ran = $false
      if ($s.ReadLine) {
        $ran = $s.Running
      } else {
        $h = Get-History -Count 1
        $id = if ($h) { $h.Id } else { 0 }
        $ran = $s.HistoryId -ge 0 -and $id -ne $s.HistoryId
        $s.HistoryId = $id
      }
      $s.Running = $false
      if ($ran) {
        # $? is false after a failed cmdlet, a throw, or a native program
        # that exited non-zero. The last also sets $LASTEXITCODE, so that
        # is the code when the command changed it, or left no new error
        # record (a failed cmdlet leaves one, a native program does not).
        # A line that runs a failing program and then a failing cmdlet
        # therefore gives the program's code.
        $status = 0
        if (-not $ok) {
          $status = 1
          # Under $PSNativeCommandUseErrorActionPreference (pwsh 7.4) a
          # program's non-zero exit leaves a record too, which is not new
          # in that sense.
          $new = -not [object]::ReferenceEquals($err, $s.Error) -and -not (
            $err -is [System.Management.Automation.ErrorRecord] -and
            $err.Exception.GetType().FullName -eq 'System.Management.Automation.NativeCommandExitException')
          if ($code -is [int] -and $code -ne 0 -and ($code -ne $s.ExitCode -or -not $new)) {
            $status = $code
          }
        }
        $pre += "$e]133;D;$status$bel"
      }

      # 133;A moves the cursor to a fresh line in the terminal, which
      # ConPTY on Windows would not know about. It never has to: PowerShell
      # ends an unfinished line before it runs the prompt.
      $pre += "$e]133;A;redraw=0$bel"

      $loc = $ExecutionContext.SessionState.Path.CurrentLocation
      $fs = $loc.Provider.Name -eq 'FileSystem'
      if ($fs -and $loc.ProviderPath -cne $s.Cwd) {
        $s.Cwd = $loc.ProviderPath
        # A directory name holding ESC or BEL would end the sequence early
        # and start one of its own.
        $dir = $loc.ProviderPath -replace '[\x00-\x1f\x7f]', ''
        if ($s.Windows) {
          $pre += "$e]9;9;`"$dir`"$bel"
        } else {
          $pre += "$e]7;kitty-shell-cwd://$($s.HostName)$dir$bel"
        }
      }
      # Before the user's prompt, so that a title it sets wins.
      if ($s.Title) {
        $title = if ($fs) { $loc.ProviderPath } else { $loc.Path }
        $pre += "$e]2;$($title -replace '[\x00-\x1f\x7f]', '')$bel"
      }
      # Written now rather than returned: a prompt that writes with
      # Write-Host has written its text before it returns.
      $Host.UI.Write($pre)
    } catch {}

    # The user's prompt, with $? as it was. As the console host does, the
    # first object it returns is the prompt, and 'PS>' stands in for none,
    # or for no prompt function at all.
    $text = ''
    if ($s.Prompt) {
      try {
        if (-not $ok) { Write-Error 'ghostty: $? is false' -ErrorAction Ignore }
        $out = @(& $s.Prompt)
        if ($out.Count -and $null -ne $out[0]) { $text = $out[0].ToString() }
      } catch {}
    }
    if ($text -eq '') { $text = 'PS>' }

    $end = "$e]133;I$bel"
    try {
      # Remove-Module PSReadLine takes its PSConsoleHostReadLine away, and
      # the console host reads the next line itself; ours goes too.
      if ($s.ReadLine -and -not (Get-Module PSReadLine)) {
        Remove-Item Function:\PSConsoleHostReadLine -ErrorAction Ignore
        $s.ReadLine = $null
        $h = Get-History -Count 1
        if ($h) { $s.HistoryId = $h.Id }
      }
      if ($s.ReadLine) {
        $end = "$e]133;B$bel"
        $opt = Get-PSReadLineOption
        if ($null -ne $s.PromptText) {
          if ((@($opt.PromptText) -join "`n") -cne $s.PromptText) {
            # The user set their own since: leave it to them.
            $s.PromptText = $null
          } else {
            # The visible end of the prompt's last line: its last
            # character that is not white space (a surrogate pair is one
            # character), and the white space after it.
            $plain = $text -replace '\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.', ''
            $last = @($plain -split '\r?\n')[-1]
            if ($last -match '(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|\S)\s*$' -and
                $Matches[0] -cne $s.PromptText) {
              Set-PSReadLineOption -PromptText $Matches[0]
              $s.PromptText = $Matches[0]
            }
          }
        }
        # Vi mode sets its own cursor.
        $s.CursorSet = $false
        if ($s.Cursor -and "$($opt.EditMode)" -ne 'Vi') {
          $end += "$e[$($s.Cursor) q"
          $s.CursorSet = $true
        }
      }
    } catch {}

    # Where the next command starts from: read again, as the user's prompt
    # can run a program itself (a git prompt). With PSReadLine the wrapper
    # reads them once more when it accepts a line.
    $s.ExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore
    $s.Error = if ($global:Error.Count) { $global:Error[0] } else { $null }
    $text + $end
  }

  if ($s.ReadLine) {
    function global:PSConsoleHostReadLine {
      [System.Diagnostics.DebuggerHidden()]
      param()
      # PSReadLine's function reads $? first, for its own use; calling it
      # first keeps that.
      $line = & $global:__GhosttyState.ReadLine
      $s = $global:__GhosttyState
      # An empty line runs nothing, and the next prompt follows.
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $e = [char]27
        $bel = [char]7
        $c = "$e]133;C$bel"
        if ($s.Title) {
          $c += "$e]2;$($line.Trim() -replace '[\x00-\x1f\x7f]+', ' ')$bel"
        }
        if ($s.CursorSet) { $c += "$e[0 q" }
        $s.Running = $true
        $s.ExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore
        $s.Error = if ($global:Error.Count) { $global:Error[0] } else { $null }
        try { $Host.UI.Write($c) } catch {}
      }
      $line
    }
  }
}
