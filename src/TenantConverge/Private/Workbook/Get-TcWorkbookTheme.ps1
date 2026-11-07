function Get-TcWorkbookTheme {
    <#
    .SYNOPSIS
    Returns the colors of the workbook: neutral, with one color per role, the same as in the report.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        Ink = '2B3445'; Muted = '6B7688'; Band = '1F2A44'; Accent = '2E62C0'; Surface = 'F5F7FB'; Line = 'E2E8F0'; Input = 'FFF7DC'; Command = 'EEF2F8'
        Roles = @{ Target = '2E62C0'; S1 = '0E8F7E'; S2 = '8A52D8'; S3 = 'D0457F'; All = '5B6678' }
        Good = @('D9F0E3', '1E6B3A'); Info = @('DCE6FB', '16244C'); Warn = @('FFF4DC', '8A5A00'); Bad = @('F8D7D3', '9B1C1C'); Plain = @('EEF0F4', '4A5568')
    }
}
