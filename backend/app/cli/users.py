"""Accounts from the command line (registration is closed in the app).

    python -m app.cli.users create --email erik@example.com [--user-id UUID]
    python -m app.cli.users set-password --email erik@example.com
    python -m app.cli.users set-plan --email erik@example.com --plan plus

The password is asked twice and never printed. A plan with room again releases the
account's deferred speech at once (workers/deferred.py).
"""

import argparse
import asyncio
import getpass
import sys
import uuid

import redis.asyncio as redis

from app.core.config import settings
from app.core.database import async_session
from app.services.passwords import create_user, set_password
from app.services.plans import plan_names, set_user_plan
from app.workers.deferred import release_deferred


def _ask_password() -> str:
    first = getpass.getpass("Password: ")
    if first != getpass.getpass("Password again: "):
        sys.exit("The two passwords differ.")
    return first


def _redis() -> redis.Redis:
    return redis.from_url(settings.redis_url)


async def _set_plan(args: argparse.Namespace) -> None:
    async with async_session() as db:
        try:
            user = await set_user_plan(db, args.email, args.plan)
        except ValueError as error:
            sys.exit(str(error).capitalize() + ".")
    print(f"{user.email} is on {user.plan}")
    client = _redis()
    try:
        released = await release_deferred(client, session_factory=async_session, user_id=user.id)
    except Exception as error:  # the hourly release picks it up
        print(f"Deferred speech not queued now ({error}); the worker does it within the hour")
        return
    finally:
        await client.aclose()
    if released:
        unit = "segment" if released == 1 else "segments"
        print(f"{released} deferred {unit} queued for transcription")


async def _main(args: argparse.Namespace) -> None:
    if args.command == "set-plan":
        await _set_plan(args)
        return
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
    plan = sub.add_parser("set-plan", help="set an account's plan")
    plan.add_argument("--email", required=True)
    plan.add_argument("--plan", required=True, help=", ".join(plan_names()))
    asyncio.run(_main(parser.parse_args()))


if __name__ == "__main__":
    main()
