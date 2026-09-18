# Run once after cloning, with TD closed. Updates only NEW project Path metadata.
$ErrorActionPreference='Stop'
$taskRepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$taskProjectFiles=@(
    (Join-Path $taskRepoRoot 'audio_board\standalone\hdmi_tone.al'),
    (Join-Path $taskRepoRoot 'pic_sdram_audio.al')
)
foreach($taskProjectFile in $taskProjectFiles){
    $taskProjectPath=(Split-Path -Parent $taskProjectFile).Replace('\','/')
    $taskXml=[System.IO.File]::ReadAllText($taskProjectFile)
    $taskXml=[regex]::Replace($taskXml,'(<Project[^>]* Path=")[^"]*',{
        param($taskMatch)
        $taskMatch.Groups[1].Value+$taskProjectPath
    })
    [System.IO.File]::WriteAllText($taskProjectFile,$taskXml,(New-Object System.Text.UTF8Encoding($false)))
    Write-Output "Project ready for GUI: $taskProjectFile"
}
