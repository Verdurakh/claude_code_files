param([string]$Message = "Claude Code needs your attention")

Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@ -Name Win32 -Namespace Native

if ([Native.Win32]::GetForegroundWindow() -eq [Native.Win32]::GetConsoleWindow()) { return }

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1)
$textElement = $template.GetElementsByTagName('text').Item(0)
$textElement.AppendChild($template.CreateTextNode($Message)) > $null
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Code')
$notifier.Show([Windows.UI.Notifications.ToastNotification]::new($template))
