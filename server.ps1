# Work Orders - local network server (no installation needed)
$port = 8000
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dd = Join-Path $root 'data'
$fd = Join-Path $root 'files'
New-Item -ItemType Directory -Force -Path $dd, $fd | Out-Null
$enc = [Text.Encoding]::ASCII
$empty = [byte[]]@()
$names = @{200='OK'; 204='No Content'; 400='Bad Request'; 404='Not Found'; 500='Server Error'}

function Send($s, [int]$code, [string]$ct, [byte[]]$b) {
    $h = "HTTP/1.1 $code $($names[$code])`r`nContent-Type: $ct`r`nContent-Length: $($b.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = $enc.GetBytes($h)
    $s.Write($hb, 0, $hb.Length)
    if ($b.Length -gt 0) { $s.Write($b, 0, $b.Length) }
    $s.Flush()
}

try {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $port)
    $l.Start()
} catch {
    Write-Host "Cannot start on port $port. Is the server already running?"
    exit
}

Write-Host ""
Write-Host "Server is running. Open one of these addresses on any device on the network:"
[Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
    ForEach-Object { Write-Host ("   http://{0}:{1}" -f $_.IPAddressToString, $port) }
Write-Host ""
Write-Host "Keep this window open. Close it to stop the server."

while ($true) {
    $c = $l.AcceptTcpClient()
    try {
        $c.ReceiveTimeout = 20000
        $c.SendTimeout = 20000
        $s = $c.GetStream()
        $buf = New-Object byte[] 65536
        $ms = New-Object IO.MemoryStream
        $hend = -1
        $t = ''
        while ($hend -lt 0) {
            $n = $s.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $t = $enc.GetString($ms.GetBuffer(), 0, [int]$ms.Length)
            $hend = $t.IndexOf("`r`n`r`n")
        }
        if ($hend -lt 0) { continue }
        $lines = $t.Substring(0, $hend) -split "`r`n"
        $rl = $lines[0] -split ' '
        $m = $rl[0]
        $url = $rl[1]
        $cl = 0
        foreach ($ln in $lines) { if ($ln -match '^(?i)content-length:\s*(\d+)') { $cl = [int]$Matches[1] } }
        $bs = $hend + 4
        while ($ms.Length -lt ($bs + $cl)) {
            $n = $s.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $body = New-Object byte[] $cl
        if ($cl -gt 0) { [Array]::Copy($ms.GetBuffer(), $bs, $body, 0, $cl) }
        $path = [Uri]::UnescapeDataString($url.Split('?')[0])
        $ctype = 'application/octet-stream'
        if ($url -match '[?&]t=([^&]+)') {
            $tt = [Uri]::UnescapeDataString($Matches[1])
            if ($tt -match '^[\w.+/-]+$') { $ctype = $tt }
        }

        if ($m -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Send $s 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $root 'index.html')))
        }
        elseif ($path -match '^/api/data/(s\d+)$') {
            $f = Join-Path $dd ($Matches[1] + '.json')
            if ($m -eq 'GET') {
                if (Test-Path $f) { Send $s 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($f)) }
                else { Send $s 404 'text/plain' $empty }
            }
            elseif ($m -eq 'PUT') {
                [IO.File]::WriteAllBytes($f + '.tmp', $body)
                Move-Item -Force ($f + '.tmp') $f
                Send $s 204 'text/plain' $empty
            }
            else { Send $s 400 'text/plain' $empty }
        }
        elseif ($path -match '^/api/file/([A-Za-z0-9_-]+)$') {
            $f = Join-Path $fd $Matches[1]
            if ($m -eq 'GET') {
                if (Test-Path $f) { Send $s 200 $ctype ([IO.File]::ReadAllBytes($f)) }
                else { Send $s 404 'text/plain' $empty }
            }
            elseif ($m -eq 'PUT') {
                [IO.File]::WriteAllBytes($f, $body)
                Send $s 204 'text/plain' $empty
            }
            elseif ($m -eq 'DELETE') {
                if (Test-Path $f) { Remove-Item -Force $f }
                Send $s 204 'text/plain' $empty
            }
            else { Send $s 400 'text/plain' $empty }
        }
        else { Send $s 404 'text/plain' $empty }
    } catch {
        Write-Host ("Request error: " + $_.Exception.Message)
    } finally {
        $c.Close()
    }
}
