function Get-TcExcelProcessId {
    <#
    .SYNOPSIS
    Returns the process identifier of an Excel instance, from its window.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][object]$Excel
    )

    if (-not ('TenantConverge.ExcelWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace TenantConverge {
    public static class ExcelWindow {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        public static int ProcessId(long window) {
            uint id;
            GetWindowThreadProcessId(new IntPtr(window), out id);
            return (int)id;
        }
    }
}
'@
    }
    [TenantConverge.ExcelWindow]::ProcessId([long]$Excel.Hwnd)
}
