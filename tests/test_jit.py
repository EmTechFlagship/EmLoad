"""JIT helpers: GDB remote attach/detach, without a device."""

from __future__ import annotations

import asyncio

import pytest

from emload.jit import JitError, _attach_and_detach, _version_at_least, debugserver_service_name, enable_jit, gdb_packet


class _FakeService:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self._closed = False

    async def recv_any(self, length: int = 4096) -> bytes:
        return await self.reader.read(length)

    async def sendall(self, payload: bytes) -> None:
        self.writer.write(payload)
        await self.writer.drain()


def test_debugserver_service_name_switches_at_ios_17():
    assert debugserver_service_name("16.7.10") == "com.apple.debugserver.DVTSecureSocketProxy"
    assert debugserver_service_name("17.0") == "com.apple.internal.dt.remote.debugproxy"
    assert debugserver_service_name("18.4.1") == "com.apple.internal.dt.remote.debugproxy"
    assert _version_at_least("17", 17)
    assert not _version_at_least("", 17)


def test_gdb_packet_checksum():
    packet = gdb_packet("QStartNoAckMode")
    assert packet.startswith(b"$QStartNoAckMode#")
    payload = b"QStartNoAckMode"
    assert packet.endswith(f"{sum(payload) & 0xFF:02x}".encode())


def test_enable_jit_requires_a_bundle_id():
    with pytest.raises(JitError, match="bundle identifier"):
        enable_jit(None, "  ")


def test_attach_and_detach_speaks_gdb_remote():
    asyncio.run(_assert_attach_dialogue())


def test_attach_refuses_an_error_reply():
    with pytest.raises(JitError, match="refused to attach"):
        asyncio.run(_assert_error_reply())


def test_bad_checksum_is_rejected():
    with pytest.raises(JitError, match="checksum"):
        asyncio.run(_assert_bad_checksum())


async def _assert_attach_dialogue() -> None:
    received: list[bytes] = []

    async def server(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # QStartNoAckMode still uses acknowledgements. The ack for OK is the
        # last '+' the client sends.
        command = await _read_command(reader)
        received.append(command)
        assert command == b"QStartNoAckMode"
        writer.write(b"+" + gdb_packet("OK"))
        await writer.drain()
        assert await reader.readexactly(1) == b"+"

        command = await _read_command(reader)
        received.append(command)
        assert command == b"QSetDetachOnError:1"
        writer.write(gdb_packet("OK"))
        await writer.drain()

        command = await _read_command(reader)
        received.append(command)
        assert command == b"vAttach;1a"
        # A console-output packet can arrive before the stop reply.
        writer.write(gdb_packet("O6869"))
        await writer.drain()
        writer.write(gdb_packet("T05thread:1;"))
        await writer.drain()

        command = await _read_command(reader)
        received.append(command)
        assert command == b"D"
        writer.write(gdb_packet("OK"))
        await writer.drain()
        writer.close()

    await _run_against(server, 0x1A)
    assert received == [
        b"QStartNoAckMode",
        b"QSetDetachOnError:1",
        b"vAttach;1a",
        b"D",
    ]


async def _assert_error_reply() -> None:
    async def server(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await _read_command(reader)
        writer.write(b"+" + gdb_packet("OK"))
        await writer.drain()
        assert await reader.readexactly(1) == b"+"
        await _read_command(reader)
        writer.write(gdb_packet("OK"))
        await writer.drain()
        await _read_command(reader)
        writer.write(gdb_packet("E96"))
        await writer.drain()
        writer.close()

    await _run_against(server, 7)


async def _assert_bad_checksum() -> None:
    async def server(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await _read_command(reader)
        writer.write(b"+$OK#00")
        await writer.drain()
        writer.close()

    await _run_against(server, 1)


class _MemoryWriter:
    """The half of an in-memory stream pair that ``feed_data``s its peer."""

    def __init__(self, peer: asyncio.StreamReader):
        self.peer = peer

    def write(self, data: bytes) -> None:
        self.peer.feed_data(data)

    async def drain(self) -> None:
        return None

    def close(self) -> None:
        if not self.peer.at_eof():
            self.peer.feed_eof()


async def _run_against(handler, pid: int) -> None:
    client_reader: asyncio.StreamReader = asyncio.StreamReader()
    server_reader: asyncio.StreamReader = asyncio.StreamReader()
    client_writer = _MemoryWriter(server_reader)
    server_task = asyncio.create_task(handler(server_reader, _MemoryWriter(client_reader)))
    try:
        await _attach_and_detach(_FakeService(client_reader, client_writer), pid)
    finally:
        client_writer.close()
        if not server_task.done():
            server_task.cancel()
        try:
            await server_task
        except asyncio.CancelledError:
            pass


async def _read_command(reader: asyncio.StreamReader) -> bytes:
    assert await reader.readexactly(1) == b"$"
    body = bytearray()
    while True:
        byte = await reader.readexactly(1)
        if byte == b"#":
            break
        body.extend(byte)
    checksum = await reader.readexactly(2)
    assert checksum == f"{sum(body) & 0xFF:02x}".encode()
    return bytes(body)
