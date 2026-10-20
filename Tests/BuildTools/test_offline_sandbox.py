import contextlib
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the macOS sandbox')
class OfflineSandboxTests(unittest.TestCase):
    def test_ip_connections_and_binding_are_denied_but_unix_ipc_works(self):
        # Loopback listeners make this independent of Internet/DNS availability.
        # A refused connection is not sufficient: require the sandbox's EPERM.
        child = r'''
import errno, socket, sys

def denied(label, operation):
    try:
        operation()
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), (label, error)
    else:
        raise AssertionError(label + ' was not blocked')

for index, (family, host, kind) in enumerate([
    (socket.AF_INET, '127.0.0.1', socket.SOCK_STREAM),
    (socket.AF_INET6, '::1', socket.SOCK_STREAM),
    (socket.AF_INET, '127.0.0.1', socket.SOCK_DGRAM),
    (socket.AF_INET6, '::1', socket.SOCK_DGRAM),
]):
    address = (host, int(sys.argv[index + 2]))
    with socket.socket(family, kind) as client:
        client.settimeout(2)
        if kind == socket.SOCK_STREAM:
            denied('TCP ' + host, lambda: client.connect(address))
        else:
            denied('UDP ' + host, lambda: client.sendto(b'offline-probe', address))
    with socket.socket(family, kind) as server:
        denied('bind ' + host, lambda: server.bind((host, 0)))

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as local:
    local.settimeout(2)
    local.connect(sys.argv[1])
    local.sendall(b'local-ipc')
'''
        with tempfile.TemporaryDirectory(prefix='ls-offline-', dir='/tmp') as temporary, \
                contextlib.ExitStack() as stack:
            path = str(Path(temporary) / 'socket')
            local = stack.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
            local.bind(path)
            local.listen(1)
            local.settimeout(2)
            ports = []
            for family, host, kind in [
                (socket.AF_INET, '127.0.0.1', socket.SOCK_STREAM),
                (socket.AF_INET6, '::1', socket.SOCK_STREAM),
                (socket.AF_INET, '127.0.0.1', socket.SOCK_DGRAM),
                (socket.AF_INET6, '::1', socket.SOCK_DGRAM),
            ]:
                server = stack.enter_context(socket.socket(family, kind))
                server.bind((host, 0))
                if kind == socket.SOCK_STREAM:
                    server.listen(1)
                ports.append(str(server.getsockname()[1]))
            result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(ROOT / 'Scripts/offline.sb'),
                                     sys.executable, '-c', child, path, *ports],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            connection, _ = local.accept()
            with connection:
                self.assertEqual(connection.recv(32), b'local-ipc')


if __name__ == '__main__':
    unittest.main()
