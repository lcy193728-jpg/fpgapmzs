# 临时脚本: 提权后把 会议配置 + 音乐 裸写入 G: 卡(物理扇区 200000 / 300000)
$ErrorActionPreference = 'Continue'
$s = 'E:\FPGA\ALST\_dev_sim_0b18789\tools\write_sd_music.ps1'

& $s -Disk 1 -Drive G -Lba 200000 -Sectors 3 `
     -Raw  'E:\FPGA\ALST\_dev_sim_0b18789\audio_final\assets\mtg1_cfg_3sec.bin' `
     -ExpectedSha256 f15bcd41d24312db9bf1fd144b4e1d1b8b7478dd011936eb89d635d6a463789c `
     -LogFile 'E:\FPGA\ALST\_dev_sim_0b18789\audio_final\build\sd_write_mtg1.log' -Write
Write-Host ("MTG1 exit = {0}" -f $LASTEXITCODE)

& $s -Disk 1 -Drive G -Lba 300000 -Sectors 38464 `
     -Raw  'E:\FPGA\ALST\_dev_sim_0b18789\audio_final\assets\wel_music_48k_mono.raw' `
     -ExpectedSha256 0d463ec052a46c5d16e125d348aa64301ec9c394b8b5810b75ef02712d1d5222 `
     -LogFile 'E:\FPGA\ALST\_dev_sim_0b18789\audio_final\build\sd_write_music.log' -Write
Write-Host ("MUSIC exit = {0}" -f $LASTEXITCODE)
