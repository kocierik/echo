"""Accounts from the command line (registration is closed in the app).

    python -m app.cli.users create --email erik@example.com [--user-id UUID]
    python -m app.cli.users set-password --email erik@example.com

The password is asked twice and never printed.
"""

import argparse
import asyncio
import getpass
import sys
import uuid

from app.core.database import async_session
from app.services.passwords import create_user, set_password


def _ask_password() -> str:
    first = getpass.getpass("Password: ")
    if first != getpass.getpass("Password again: "):
        sys.exit("The two passwords differ.")
    return first


async def _main(args: argparse.Namespace) -> None:
    password = _ask_password()
    async with async_session() as db:
        try:
            if args.command == "create":
                user = await create_user(db, args.email, password, user_id=args.user_id)
                print(f"Created {user.email} ({user.id})")
            else:
                answer = input("Sign out every device of this account too? [y/N] ")
                signed_out = await set_password(
                    db, args.email, password, sign_out_devices=answer.strip().lower() == "y"
                )
                print(f"Password changed for {args.email.strip().lower()}")
                if signed_out:
                    print(f"{signed_out} device(s) signed out: they sign in again")
        except ValueError as error:
            sys.exit(str(error).capitalize() + ".")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli.users")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create", help="create an account")
    create.add_argument("--email", required=True)
    create.add_argument("--user-id", type=uuid.UUID, default=None)
    reset = sub.add_parser("set-password", help="set an account's password")
    reset.add_argument("--email", required=True)
    asyncio.run(_main(parser.parse_args()))


if __name__ == "__main__":
    main()
