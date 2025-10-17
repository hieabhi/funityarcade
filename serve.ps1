<#
  Simple static server for current directory.
  - Binds to 127.0.0.1 (IPv4 loopback)
  - Tries the specified port, or falls back to the next free port range when -AutoPort is used
  - Prints the exact URL on success; emits clear diagnostics on failure
#>
param(
  [int]$Port = 8080,
  [switch]$AutoPort
)

$bindIp = [System.Net.IPAddress]::Loopback  # 127.0.0.1

# Resolve server root early so we can write helper files
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function New-Listener([int]$p) {
  $l = New-Object System.Net.Sockets.TcpListener($bindIp, $p)
  try {
    $l.Start()
    return $l
  } catch {
    # If address already in use (WSAEADDRINUSE 10048), return $null so caller can try next port
    $ex = $_.Exception
    $isSocket = ($ex -is [System.Net.Sockets.SocketException])
    $code = if ($isSocket) { $ex.ErrorCode } else { 0 }
    if ($isSocket -and $code -eq 10048) { return $null }
    throw
  }
}

$listener = $null
if ($AutoPort) {
  $start = $Port
  $end = $Port + 20
  foreach ($p in $start..$end) {
    $listener = New-Listener -p $p
    if ($listener) { $Port = $p; break }
  }
  if (-not $listener) {
    Write-Error "Failed to start server on any port in range $start-$end. Check if another app is using them."
    Write-Host "Tip: List usage with: netstat -ano | findstr :$start"
    exit 1
  }
} else {
  try {
    $listener = New-Listener -p $Port
  } catch {
    $msg = $_.Exception.Message
    Write-Error "Failed to start server on port $Port. $msg"
    Write-Host "Tip: If it's in use, try: powershell -NoProfile -File .\\serve.ps1 -AutoPort"
    Write-Host "      Or check: netstat -ano | findstr :$Port"
    exit 1
  }
}

Write-Host ("Serving {0} at http://127.0.0.1:{1}/ (Ctrl+C to stop)" -f $PWD, $Port)
# Persist chosen port for helper tasks
try {
  $portFile = Join-Path $root ".server-port"
  Set-Content -Path $portFile -Value $Port -Encoding ASCII -Force | Out-Null
} catch { }

function Get-ContentType($path) {
  switch ([IO.Path]::GetExtension($path).ToLower()) {
    ".html" { "text/html; charset=utf-8" }
    ".htm"  { "text/html; charset=utf-8" }
    ".css"  { "text/css; charset=utf-8" }
    ".js"   { "application/javascript; charset=utf-8" }
    ".json" { "application/json; charset=utf-8" }
    ".png"  { "image/png" }
    ".jpg"  { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".gif"  { "image/gif" }
    ".svg"  { "image/svg+xml" }
    default { "application/octet-stream" }
  }
}

function Handle-Client($client) {
  try {
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 8192, $true)
    $writer = New-Object System.IO.StreamWriter($stream, [Text.Encoding]::ASCII, 8192, $true)
    $writer.NewLine = "\r\n"

    # Read request line
    $requestLine = $reader.ReadLine()
    if (-not $requestLine) { return }
    $parts = $requestLine.Split(' ')
    $method = $parts[0]
    $rawPath = $parts[1]

    # Drain headers
    while ($true) { $line = $reader.ReadLine(); if ($null -eq $line -or $line -eq '') { break } }

    if ($method -ne 'GET' -and $method -ne 'HEAD') {
      $writer.WriteLine("HTTP/1.1 405 Method Not Allowed")
      $writer.WriteLine("Allow: GET, HEAD")
      $writer.WriteLine("Connection: close")
      $writer.WriteLine()
      Write-Host ("{0} {1} -> 405" -f $method, $rawPath)
      return
    }

    $relPath = [Uri]::UnescapeDataString($rawPath.TrimStart('/'))
    if ([string]::IsNullOrWhiteSpace($relPath)) { $relPath = 'index.html' }
    $safePath = Join-Path $root $relPath
    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $safePath -ErrorAction Stop).Path } catch {}
    if (-not $resolved) {
      $body = [Text.Encoding]::UTF8.GetBytes("404 Not Found")
      $writer.WriteLine("HTTP/1.1 404 Not Found")
      $writer.WriteLine("Content-Type: text/plain; charset=utf-8")
      $writer.WriteLine("Content-Length: {0}" -f $body.Length)
      $writer.WriteLine("Cache-Control: no-cache")
      $writer.WriteLine("Connection: close")
      $writer.WriteLine()
      $writer.Flush()
      $stream.Write($body, 0, $body.Length)
      Write-Host ("{0} {1} -> 404" -f $method, $rawPath)
      return
    }
    if (-not $resolved.StartsWith($root)) {
      $body = [Text.Encoding]::UTF8.GetBytes("403 Forbidden")
      $writer.WriteLine("HTTP/1.1 403 Forbidden")
      $writer.WriteLine("Content-Type: text/plain; charset=utf-8")
      $writer.WriteLine("Content-Length: {0}" -f $body.Length)
      $writer.WriteLine("Cache-Control: no-cache")
      $writer.WriteLine("Connection: close")
      $writer.WriteLine()
      $writer.Flush()
      $stream.Write($body, 0, $body.Length)
      Write-Host ("{0} {1} -> 403" -f $method, $rawPath)
      return
    }

    if (Test-Path -LiteralPath $resolved -PathType Container) {
      $resolved = Join-Path $resolved 'index.html'
    }

    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
      try {
        $bytes = [IO.File]::ReadAllBytes($resolved)
        $ctype = Get-ContentType $resolved
        $writer.WriteLine("HTTP/1.1 200 OK")
        $writer.WriteLine("Content-Type: $ctype")
        $writer.WriteLine("X-Content-Type-Options: nosniff")
        $writer.WriteLine("Content-Length: {0}" -f $bytes.Length)
        $writer.WriteLine("Cache-Control: no-cache")
        $writer.WriteLine("Connection: close")
        $writer.WriteLine()
        $writer.Flush()
        if ($method -eq 'GET') {
          $stream.Write($bytes, 0, $bytes.Length)
        }
        Write-Host ("{0} {1} -> 200 {2}" -f $method, $rawPath, (Split-Path -Leaf $resolved))
      } catch {
        $body = [Text.Encoding]::UTF8.GetBytes("500 Server Error")
        $writer.WriteLine("HTTP/1.1 500 Internal Server Error")
        $writer.WriteLine("Content-Type: text/plain; charset=utf-8")
        $writer.WriteLine("Content-Length: {0}" -f $body.Length)
        $writer.WriteLine("Connection: close")
        $writer.WriteLine()
        $writer.Flush()
        $stream.Write($body, 0, $body.Length)
        Write-Host ("{0} {1} -> 500" -f $method, $rawPath)
      }
    } else {
      $body = [Text.Encoding]::UTF8.GetBytes("404 Not Found")
      $writer.WriteLine("HTTP/1.1 404 Not Found")
      $writer.WriteLine("Content-Type: text/plain; charset=utf-8")
      $writer.WriteLine("Content-Length: {0}" -f $body.Length)
      $writer.WriteLine("Connection: close")
      $writer.WriteLine()
      $writer.Flush()
      $stream.Write($body, 0, $body.Length)
      Write-Host ("{0} {1} -> 404" -f $method, $rawPath)
    }
  } finally {
    try { $client.Close() } catch {}
  }
}

while ($true) {
  try {
    $client = $listener.AcceptTcpClient()
    Handle-Client $client
  } catch {
    Start-Sleep -Milliseconds 50
    continue
  }
}

try { $listener.Stop() } catch {}
