# POC-Powershell-Reverse-Shell
A simple Powershell reverse shell for demonstrating the concept as simply as possible with no encryption or tunneling.

## Basic concept
1. Initiate a TCP socket connection back to the listener server (typically Netcat)
2. Initiate a Powershell instance as a child process (can be any process that uses stdin, stdout, and stderr)
3. Create a thread to send the process' stdout stream output through the socket stream to the server
4. Create a thread to send the process' stderr stream output through the socket stream to the server
5. Create a thread to send the socket output through the process' stdin stream
6. Yield the main thread until the connection terminates or the process exits and then clean up the environment