#!/usr/bin/env python3
# winrun.py PORT TOKENFILE DEADLINE_MS OUT EXE [FILES...]: one job on the
# probe image's runner: the files go over (the first is the program), its
# stdout comes back into OUT; prints "<name> <exit code>" (or "timeout")
import os, socket, struct, sys, time

port, token_file, deadline, out, exe = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
files = [exe] + sys.argv[6:]
token = open(token_file, 'rb').read()
req = b'DWR1' + token + struct.pack('<III', deadline, 0, len(files))
for f in files:
    name = os.path.basename(f).encode()
    data = open(f, 'rb').read()
    req += struct.pack('<I', len(name)) + name + struct.pack('<I', len(data)) + data

def read_all(s, n):
    b = b''
    while len(b) < n:
        chunk = s.recv(n - len(b))
        if not chunk:
            raise EOFError
        b += chunk
    return b

s = socket.create_connection(('127.0.0.1', port), timeout=deadline / 1000 + 60)
s.sendall(req)
if read_all(s, 4) != b'DWR1':
    sys.exit('bad answer')
code, late, n = struct.unpack('<III', read_all(s, 12))
stdout = read_all(s, n)
(n,) = struct.unpack('<I', read_all(s, 4))
read_all(s, n)
open(out, 'wb').write(stdout)
name = os.path.splitext(os.path.basename(exe))[0]
print(f'{name} {"timeout" if late else code}')
