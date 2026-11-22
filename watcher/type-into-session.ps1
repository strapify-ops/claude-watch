# Claude Watch: send a message into a LIVE Claude desktop session (not a headless copy), so it
# keeps the session's tools (Chrome, computer use, connectors) and shows in the app window.
# Opens the session by its claude:// link, optionally switches model / effort in the app's own
# "Model: <model> <effort>" menu, pastes the text into the "Prompt" box and presses Enter.
# Adapted from Claudette's type-into-claude.ps1 + new-session.ps1 (claude-phone).
# Prints one line: "ok" or "fail: <reason>".
param(
  [Parameter(Mandatory)] [string] $SessionId,   # desktop id, local_...
  [Parameter(Mandatory)] [string] $TextFile,
  [string] $Model = '',    # menu label, e.g. "Sonnet 5.5"
  [string] $Effort = '',   # menu label: Low, Medium, High, Extra, Max
  [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CwWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
$UIA = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]::Descendants

function Fail($why) { "fail: $why"; exit 1 }
function Get-ClaudeWindow {
  Get-Process -Name claude -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like '*\WindowsApps\Claude_*' } | Select-Object -First 1
}
function Test-ClaudeInFront($p) {
  $fgPid = 0; [void][CwWin]::GetWindowThreadProcessId([CwWin]::GetForegroundWindow(), [ref]$fgPid); return $fgPid -eq $p.Id
}
function Bring-Front {
  if ([CwWin]::IsIconic($h)) { [void][CwWin]::ShowWindow($h, 9) }
  [CwWin]::keybd_event(0x87, 0, 0, [UIntPtr]::Zero); [CwWin]::keybd_event(0x87, 0, 2, [UIntPtr]::Zero)  # F24, not Alt (Alt arms the menu bar)
  [void][CwWin]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 400
}
function Get-Buttons {
  $root.FindAll($Scope, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
}
function Get-ModelButton { Get-Buttons | Where-Object { $_.Current.Name -like 'Model: *' } | Select-Object -First 1 }
function Find-Named($type, $prefix) {
  $cond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)
  $root.FindAll($Scope, $cond) | Where-Object { $_.Current.Name -and ($_.Current.Name -eq $prefix -or $_.Current.Name.StartsWith("$prefix ")) } | Select-Object -First 1
}
function Close-Menus { [System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Start-Sleep -Milliseconds 150 }
function Open-ModelMenu($want) {
  for ($try = 0; $try -lt 4; $try++) {
    $m = Get-ModelButton
    if ($m) {
      try { $m.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}
      for ($w = 0; $w -lt 8; $w++) {
        Start-Sleep -Milliseconds 250
        $hit = Find-Named ([System.Windows.Automation.ControlType]::$($want[0])) $want[1]
        if ($hit) { return $hit }
      }
      Close-Menus
    }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

$text = [IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8)
if (-not $text.Trim()) { Fail 'empty message' }
$proc = Get-ClaudeWindow
if (-not $proc) { Fail 'the Claude desktop app is not open' }

Start-Process "claude://claude.ai/epitaxy/$SessionId"
Start-Sleep -Milliseconds 1500
$proc = Get-ClaudeWindow
$h = $proc.MainWindowHandle
if (-not (Test-ClaudeInFront $proc)) { Bring-Front }
if (-not (Test-ClaudeInFront $proc)) { Fail 'could not bring the Claude window to the front (is the PC locked?)' }
$root = $UIA::FromHandle($h)

# The message box: the focused one if the link focused it, else the only one.
$isPrompt = New-Object System.Windows.Automation.AndCondition(
  (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)),
  (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, 'Prompt')))
$box = $null
for ($i = 0; $i -lt 8 -and -not $box; $i++) {
  $prompts = $root.FindAll($Scope, $isPrompt)
  $focused = $UIA::FocusedElement
  foreach ($p in $prompts) { if ($focused -and [System.Windows.Automation.Automation]::Compare($p, $focused)) { $box = $p } }
  if (-not $box -and $prompts.Count -eq 1) { $box = $prompts[0] }
  if (-not $box -and $prompts.Count -gt 1) { Fail 'more than one session is open side by side; close the split view' }
  if (-not $box) { Start-Sleep -Milliseconds 250 }
}
if (-not $box) { Fail 'no message box found in the Claude window' }

# Model / effort, checked on the button label. Skipped when already set.
$mb = Get-ModelButton
$label = if ($mb) { $mb.Current.Name } else { '' }
if ($Model -and $label -like "Model: $Model *") { $Model = '' }
if ($Effort -and $label -like "Model: * $Effort*") { $Effort = '' }
if (($Model -or $Effort) -and -not $mb) { Fail 'no model menu in this session' }
if ($Model -and -not $DryRun) {
  $r = Open-ModelMenu @('RadioButton', $Model)
  if (-not $r) { Close-Menus; Fail "no '$Model' model in the menu" }
  $r.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 400
  if ((Get-ModelButton).Current.Name -notlike "Model: $Model *") { Close-Menus; Fail "the model did not change to $Model" }
}
if ($Effort -and -not $DryRun) {
  $e = Open-ModelMenu @('MenuItem', 'Effort')
  if (-not $e) { Close-Menus; Fail 'no Effort item in the model menu' }
  $r = $null
  for ($i = 0; $i -lt 4 -and -not $r; $i++) {
    if (-not (Test-ClaudeInFront $proc)) { Bring-Front }
    $f = $UIA::FocusedElement
    if (-not ($f -and [System.Windows.Automation.Automation]::Compare($e, $f))) { $e.SetFocus() }
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}'); Start-Sleep -Milliseconds 600
    $r = Find-Named ([System.Windows.Automation.ControlType]::RadioButton) $Effort
  }
  if (-not $r) { Close-Menus; Close-Menus; Fail "no '$Effort' effort in the menu" }
  $r.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 400
  if ((Get-ModelButton).Current.Name -notlike "Model: * $Effort*") { Close-Menus; Close-Menus; Fail "the effort did not change to $Effort" }
}
if (@($root.FindAll($Scope, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Menu))) |
    Where-Object { $_.Current.Name -like 'Model: *' -or $_.Current.Name -like 'Effort *' }).Count) { Close-Menus; Close-Menus }

$box.SetFocus()
Start-Sleep -Milliseconds 200
$focused = $UIA::FocusedElement
if (-not ($focused -and [System.Windows.Automation.Automation]::Compare($box, $focused))) { Fail 'could not put the cursor in the message box' }
if (-not (Test-ClaudeInFront $proc)) { Fail 'another window took the front' }
if ($DryRun) { "ok (dry run; model button: $label)"; exit 0 }

# Paste line by line in short pieces (one long paste arrives as <pasted_content>), Shift+Enter
# between lines, then Enter. The old clipboard is put back.
$saved = $null
try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
$lines = ($text -replace "`r`n", "`n") -split "`n"
for ($li = 0; $li -lt $lines.Count; $li++) {
  if ($li -gt 0) { [System.Windows.Forms.SendKeys]::SendWait('+{ENTER}'); Start-Sleep -Milliseconds 40 }
  $line = $lines[$li]
  for ($at = 0; $at -lt $line.Length; $at += 120) {
    Set-Clipboard -Value $line.Substring($at, [Math]::Min(120, $line.Length - $at))
    [System.Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 60
  }
}
Start-Sleep -Milliseconds 300
if (-not (Test-ClaudeInFront $proc)) { Fail 'another window took the front before sending' }
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Milliseconds 300
try { if ($null -ne $saved) { Set-Clipboard -Value $saved } else { [System.Windows.Forms.Clipboard]::Clear() } } catch {}
'ok'
