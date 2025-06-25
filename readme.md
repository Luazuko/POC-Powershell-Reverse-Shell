# POC-Powershell-Reverse-Shell
A simple Powershell reverse shell for demonstrating the concept as simply as possible with no encryption or tunneling.

## Basic concept
1. Initiate a TCP socket connection back to the listener server (typically Netcat)
2. Initiate a Powershell instance as a child process (can be any process that uses pipes for input and output)
3. Create a thread to send the process' stdout pipe output through the socket to the server
4. Create a thread to send the process' stderr pipe output through the socket to the server
5. Create a thread to send the socket output through the process' stdin pipe
6. Yield the main thread until the connection terminates and then clean up the environment