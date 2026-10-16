"""Publish a wearable firmware from inside the server (`make firmware-release` runs this).

    python -m app.cli.firmware publish --version 0.5.0 [--notes "what changed"] < firmware.bin

The image comes on standard input, so the script on the Mac pipes it into the container.
"""

import argparse
import asyncio
import sys

from app.core.database import async_session
from app.services.firmware import MAX_IMAGE_BYTES, InvalidFirmwareError, publish_release


async def _main(args: argparse.Namespace) -> None:
    data = sys.stdin.buffer.read(MAX_IMAGE_BYTES + 1)
    async with async_session() as db:
        try:
            release, created = await publish_release(db, args.version, args.notes, data)
        except InvalidFirmwareError as error:
            sys.exit(f"{error}.")
    if created:
        print(f"Published {release.version}: the app will offer it.")
    else:
        print(f"{release.version} was already published with this same image.")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli.firmware")
    sub = parser.add_subparsers(dest="command", required=True)
    publish = sub.add_parser("publish", help="publish the image read from standard input")
    publish.add_argument("--version", required=True, help="as in firmware/src/config.h")
    publish.add_argument("--notes", default=None)
    asyncio.run(_main(parser.parse_args()))


if __name__ == "__main__":
    main()
