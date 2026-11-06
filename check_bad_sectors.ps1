# 接続されているHDDの不良セクタ数を smartctl で調べて表示する (Windows / PowerShell 版)
# 不良セクタ数 = Reallocated_Sector_Ct(5) + Current_Pending_Sector(197) + Offline_Uncorrectable(198)
# 不良セクタが 0 のディスクは、そのディスク上のボリュームに約1GBのテストファイルを書き込み、
# OS のキャッシュを経由せずに読み戻してチェックサムを比較する。テストファイルは終了時(中断時含む)に必ず削除する。
# 使い方: (管理者として) .\check_bad_sectors.ps1 [-h] [DEVICE...]
#   DEVICE を省略すると全ディスクが対象。例: .\check_bad_sectors.ps1 /dev/sdb pd2
#   テストサイズ変更: $env:TEST_MB=512; .\check_bad_sectors.ps1
#   実行ポリシーで弾かれる場合: powershell -ExecutionPolicy Bypass -File .\check_bad_sectors.ps1
param(
    [switch]$h,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Device
)

$TestMB = if ($env:TEST_MB) { [int]$env:TEST_MB } else { 1024 }
$script:TestFile = $null

if ($h -or $Device -contains '-h' -or $Device -contains '--help') {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 8 | Select-Object -Skip 4 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 0
}

if ($env:OS -ne 'Windows_NT') {
    [Console]::Error.WriteLine("This script is for Windows. Use check_bad_sectors.sh on macOS / Linux.")
    exit 2
}

$Smartctl = (Get-Command smartctl -ErrorAction SilentlyContinue).Source
if (-not $Smartctl) {
    $p = Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe'
    if (Test-Path -LiteralPath $p) { $Smartctl = $p }
}
if (-not $Smartctl) {
    [Console]::Error.WriteLine("smartctl not found (winget install smartmontools.smartmontools / choco install smartmontools)")
    exit 2
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator: SMART will probably be unavailable."
}

# 読み戻しは FILE_FLAG_NO_BUFFERING で行う。このフラグは読み込みバッファのアドレスと
# サイズがセクタ境界に揃っている必要があるため、VirtualAlloc で確保したメモリに読む。
if (-not ('SmartIoTest' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public static class SmartIoTest {
    const uint GENERIC_READ = 0x80000000;
    const uint FILE_SHARE_READ = 1;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint MEM_RELEASE = 0x8000;
    const uint PAGE_READWRITE = 4;
    const int CHUNK = 1048576;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint toRead, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

    static string Hex(byte[] b) {
        return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant();
    }

    // 乱数を書き込み、書いたデータの SHA-256 を返す
    public static string WriteRandom(string path, int mb) {
        byte[] buf = new byte[CHUNK];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
        using (SHA256 sha = SHA256.Create())
        using (FileStream fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                                              FileShare.None, CHUNK, FileOptions.WriteThrough)) {
            for (int i = 0; i < mb; i++) {
                rng.GetBytes(buf);
                sha.TransformBlock(buf, 0, CHUNK, null, 0);
                fs.Write(buf, 0, CHUNK);
            }
            fs.Flush(true);
            sha.TransformFinalBlock(buf, 0, 0);
            return Hex(sha.Hash);
        }
    }

    // キャッシュを経由せずに読み、SHA-256 を返す
    public static string ReadNoCache(string path) {
        SafeFileHandle h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
                                       FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
        if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr mem = VirtualAlloc(IntPtr.Zero, (UIntPtr)CHUNK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (mem == IntPtr.Zero) {
            h.Dispose();
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            byte[] buf = new byte[CHUNK];
            using (SHA256 sha = SHA256.Create()) {
                while (true) {
                    uint n;
                    if (!ReadFile(h, mem, (uint)CHUNK, out n, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (n == 0) break;
                    Marshal.Copy(mem, buf, 0, (int)n);
                    sha.TransformBlock(buf, 0, (int)n, null, 0);
                }
                sha.TransformFinalBlock(buf, 0, 0);
                return Hex(sha.Hash);
            }
        } finally {
            VirtualFree(mem, UIntPtr.Zero, MEM_RELEASE);
            h.Dispose();
        }
    }
}
'@
}

# smartctl のデバイス名から Windows のディスク番号を求める
#   /dev/sda = PhysicalDrive0, /dev/sdb = 1, ... /dev/sdaa = 26 / /dev/pdN = PhysicalDriveN
#   それ以外(/dev/nvme0 など)はシリアル番号で Get-Disk と照合する
function Get-DiskNumber([string]$dev, [string]$type) {
    if ($dev -match '^/dev/sd([a-z]+)$') {
        $n = 0
        foreach ($c in $Matches[1].ToCharArray()) { $n = $n * 26 + ([int]$c - [int][char]'a' + 1) }
        return $n - 1
    }
    if ($dev -match '^/dev/pd(\d+)$') { return [int]$Matches[1] }

    $a = @('-i')
    if ($type) { $a += '-d', $type }
    $a += $dev
    $info = & $Smartctl @a 2>$null
    $serial = $null
    foreach ($l in $info) {
        if ($l -match '^Serial Number:\s*(.+?)\s*$') { $serial = $Matches[1]; break }
    }
    if (-not $serial) { return $null }
    $disk = Get-Disk | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq $serial } | Select-Object -First 1
    if ($disk) { return [int]$disk.Number }
    return $null
}

# 戻り値: 0=OK, 1=NG, 2=SKIP(テスト先なし/容量不足)
function Invoke-IoTest([int]$num) {
    $need = [int64]$TestMB * 1MB * 12 / 10
    $dir = $null
    foreach ($part in Get-Partition -DiskNumber $num -ErrorAction SilentlyContinue) {
        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
        if (-not $vol -or $vol.SizeRemaining -le $need) { continue }
        foreach ($p in $part.AccessPaths) {
            if (-not $p -or $p -like '\\?\*') { continue }
            $probe = Join-Path $p ".smart_io_probe.$PID"
            try {
                [IO.File]::Create($probe).Dispose()
                Remove-Item -LiteralPath $probe -Force
                $dir = $p
                break
            } catch {
                continue
            }
        }
        if ($dir) { break }
    }
    if (-not $dir) { return 2 }

    $script:TestFile = Join-Path $dir ".smart_io_test.$PID"
    $wsum = $null
    $rsum = $null
    try {
        $wsum = [SmartIoTest]::WriteRandom($script:TestFile, $TestMB)
        $rsum = [SmartIoTest]::ReadNoCache($script:TestFile)
    } catch {
        [Console]::Error.WriteLine("IO error: $($_.Exception.Message)")
    } finally {
        Remove-Item -LiteralPath $script:TestFile -Force -ErrorAction SilentlyContinue
        $script:TestFile = $null
    }

    if ($wsum -and $wsum -eq $rsum) { return 0 }
    return 1
}

# 引数でディスクが指定されていればそれだけ、なければ全ディスクを対象にする
$targets = @()
if ($Device) {
    foreach ($arg in $Device) {
        $d = if ($arg -like '/*') { $arg } else { "/dev/$arg" }
        $num = Get-DiskNumber $d ''
        if ($null -eq $num -or -not (Get-Disk -Number $num -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine("${arg}: no such device")
            exit 2
        }
        $targets += [pscustomobject]@{ Dev = $d; Type = '' }
    }
} else {
    foreach ($line in (& $Smartctl --scan)) {
        if ($line -match '^(\S+)(?:\s+-d\s+(\S+))?') {
            $targets += [pscustomobject]@{ Dev = $Matches[1]; Type = $Matches[2] }
        }
    }
}

$total = 0
$ioFailed = 0

foreach ($t in $targets) {
    $dev = $t.Dev
    # USB-SATA ブリッジは -d sat でないと SMART を返さないことがあるため、順に試す
    $attrs = $null
    $types = @($t.Type, '', 'sat') | Where-Object { $null -ne $_ } | Select-Object -Unique
    foreach ($dt in $types) {
        $a = @('-A')
        if ($dt) { $a += '-d', $dt }
        $a += $dev
        $out = & $Smartctl @a 2>$null
        if ($out -match 'RAW_VALUE') { $attrs = $out; break }
    }

    if ($attrs) {
        # 先頭の数値部分のみを RAW 値として加算する
        $count = 0
        foreach ($l in $attrs) {
            $f = -split $l
            if ($f.Count -ge 10 -and $f[0] -in '5', '197', '198' -and $f[9] -match '^\d+') {
                $count += [int64]$Matches[0]
            }
        }
        Write-Output "$dev Failed: $count"
        $total += $count
    } else {
        # SMART が読めなくても読み書きテストは行う
        $count = 0
        Write-Output "$dev Failed: N/A (SMART unavailable)"
    }

    # 不良セクタ0(または SMART 取得不可)のディスクのみ実読み書きテスト
    if ($count -eq 0) {
        $num = Get-DiskNumber $dev $t.Type
        $r = if ($null -eq $num) { 2 } else { Invoke-IoTest $num }
        switch ($r) {
            0 { Write-Output "$dev IO test: OK (${TestMB}MB)" }
            2 { Write-Output "$dev IO test: SKIP (no writable mount with enough space)" }
            default { Write-Output "$dev IO test: FAILED"; $ioFailed++ }
        }
    }
}

Write-Output "Total Failed: $total"
Write-Output "IO Test Failed: $ioFailed"

if ($total -eq 0 -and $ioFailed -eq 0) { exit 0 }
exit 1
