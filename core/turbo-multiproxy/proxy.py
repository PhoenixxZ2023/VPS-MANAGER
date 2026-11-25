"""Entrada TCP compartilhada para BHTTP e WebSocket HTTP/1.1."""
import argparse
import asyncio
import logging
from contextlib import suppress


async def identify(reader, cfg):
    first = await reader.readexactly(1)
    if first[0] in (0, 1, 3, 4):
        header = first + await reader.readexactly(28)
        if int.from_bytes(header[-4:], "big") > 2 * 1024 * 1024:
            raise ValueError("Tamanho BHTTP inválido")
        return cfg.bhttp, header
    if first != b"G":
        raise ValueError("Protocolo desconhecido")
    header = first + await reader.readuntil(b"\r\n\r\n")
    lines = header[:-4].decode("latin-1").split("\r\n")
    method, target, version = lines[0].split()
    if (method, target.partition("?")[0], version) != ("GET", cfg.path, "HTTP/1.1"):
        raise ValueError("Rota WebSocket desconhecida")
    fields = {}
    for line in lines[1:]:
        key, value = line.split(":", 1)
        fields.setdefault(key.lower(), set()).update(v.strip().lower() for v in value.split(","))
    if "websocket" not in fields.get("upgrade", ()) or "upgrade" not in fields.get("connection", ()):
        raise ValueError("Upgrade WebSocket ausente")
    return cfg.websocket, header


async def relay(reader, writer):
    while True:
        data = await reader.read(65536)
        if not data:
            writer.write_eof()
            await writer.drain()
            return
        writer.write(data)
        await writer.drain()


async def handle(reader, writer, cfg):
    upstream = None
    tasks = []
    try:
        port, header = await asyncio.wait_for(identify(reader, cfg), 10)
        source, upstream = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port), 5)
        upstream.write(header)
        await upstream.drain()
        tasks = [asyncio.create_task(relay(reader, upstream)), asyncio.create_task(relay(source, writer))]
        await asyncio.gather(*tasks)
    except (OSError, ValueError, EOFError, asyncio.TimeoutError, asyncio.LimitOverrunError) as error:
        logging.debug("Conexão encerrada: %s", error)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for stream in (writer, upstream):
            if stream is not None:
                stream.close()
                with suppress(OSError, asyncio.TimeoutError):
                    await asyncio.wait_for(stream.wait_closed(), 2)


async def main(cfg):
    server = await asyncio.start_server(lambda r, w: handle(r, w, cfg), "0.0.0.0", cfg.port, limit=16384)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("port", "bhttp", "websocket"):
        parser.add_argument("--" + option, type=int, required=True)
    parser.add_argument("--path", default="/ws")
    config = parser.parse_args()
    ports = {config.port, config.bhttp, config.websocket}
    if len(ports) != 3 or min(ports) < 1 or max(ports) > 65535:
        parser.error("Escolha três portas distintas entre 1 e 65535.")
    asyncio.run(main(config))
