import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 8002))
s.listen(1)
print("listening 8002", flush=True)
c, a = s.accept()
print("connected", a, flush=True)
data = b""
while b"\r\n\r\n" not in data:
    data += c.recv(4096)
head, _, rest = data.partition(b"\r\n\r\n")
cl = 0
for line in head.split(b"\r\n"):
    if line.lower().startswith(b"content-length:"):
        cl = int(line.split(b":")[1].strip())
print("content-length", cl, flush=True)
got = len(rest)
out = open("ero1.bin", "wb")
out.write(rest)
while got < cl:
    chunk = c.recv(1 << 20)
    if not chunk: break
    out.write(chunk)
    got += len(chunk)
    if got % (50 << 20) < (1 << 20): print("got", got, flush=True)
out.close()
c.close()
print("saved", got, flush=True)
