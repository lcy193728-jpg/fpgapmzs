param([Parameter(Mandatory=$true)][string]$OutputPath)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not ('MeetingCaptureNative' -as [type])) { Add-Type @'
using System;
using System.Runtime.InteropServices;
public class MeetingCaptureNative {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h,IntPtr rect,IntPtr region,uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT rect);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
}
'@
}
[MeetingCaptureNative]::SetProcessDPIAware() | Out-Null
$waveProcess=Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -eq 'vish' -and $_.MainWindowTitle -eq 'Wave' } | Select-Object -First 1
if(!$waveProcess) { $waveProcess=Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match 'ModelSim' } | Select-Object -First 1 }
if(!$waveProcess) { throw 'ModelSim GUI window not found; no screenshot produced.' }
$waveHandle=[MeetingCaptureNative]::FindWindow($null,'Wave')
if($waveHandle -eq [IntPtr]::Zero) { $waveHandle=$waveProcess.MainWindowHandle }
[MeetingCaptureNative]::ShowWindow($waveHandle,3) | Out-Null
[MeetingCaptureNative]::SetForegroundWindow($waveHandle) | Out-Null
[MeetingCaptureNative]::RedrawWindow($waveHandle,[IntPtr]::Zero,[IntPtr]::Zero,0x185) | Out-Null
Start-Sleep -Milliseconds 700
$waveRect=New-Object MeetingCaptureNative+RECT
[MeetingCaptureNative]::GetWindowRect($waveHandle,[ref]$waveRect) | Out-Null
$bitmap=New-Object Drawing.Bitmap(($waveRect.Right-$waveRect.Left),($waveRect.Bottom-$waveRect.Top))
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$deviceContext=$graphics.GetHdc()
$printed=[MeetingCaptureNative]::PrintWindow($waveHandle,$deviceContext,2)
$graphics.ReleaseHdc($deviceContext)
if(!$printed) { $graphics.Dispose();$bitmap.Dispose();throw 'ModelSim window capture failed; no desktop screenshot substituted.' }
$bitmap.Save($OutputPath,[Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose();$bitmap.Dispose()
