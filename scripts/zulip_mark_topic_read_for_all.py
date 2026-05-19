#!/usr/bin/env python3
"""Mark every UserMessage row for a Zulip (stream, topic) read for all subscribers.

Runs against Zulip's Django ORM. Zulip ships no public API to force-read on
behalf of other users — this script fills that gap so the watchdog can clear
everyone's unread count when an incident is resolved.

Invocation: must be executed by the Zulip venv interpreter so DJANGO_SETTINGS_MODULE
and zerver/ are on sys.path. The companion wrapper (zulip-mark-topic-read-for-all)
handles su zulip + venv selection.

Marks both the live topic name and its resolved counterpart (✔ TOPIC) so the
caller can resolve-then-mark or mark-then-resolve without worrying about order.
"""
import os
import sys

DEPLOYMENT = os.environ.get("ZULIP_DEPLOYMENT", "/home/zulip/deployments/current")
sys.path.insert(0, DEPLOYMENT)
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "zproject.settings")

import django  # noqa: E402
django.setup()

from django.db.models import F  # noqa: E402
from zerver.models import Message, Recipient, Stream, UserMessage  # noqa: E402


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: zulip_mark_topic_read_for_all.py STREAM TOPIC", file=sys.stderr)
        return 2
    stream_name, topic_name = sys.argv[1], sys.argv[2]
    if not stream_name or not topic_name:
        print("STREAM and TOPIC must be non-empty", file=sys.stderr)
        return 2

    subjects = [topic_name]
    if not topic_name.startswith("✔ "):
        subjects.append(f"✔ {topic_name}")

    total = 0
    streams = list(Stream.objects.filter(name=stream_name))
    if not streams:
        print(f"stream not found: {stream_name}", file=sys.stderr)
        return 3
    for stream in streams:
        try:
            recipient = Recipient.objects.get(type=Recipient.STREAM, type_id=stream.id)
        except Recipient.DoesNotExist:
            continue
        for subj in subjects:
            msg_ids = list(
                Message.objects.filter(recipient=recipient, subject=subj)
                .values_list("id", flat=True)
            )
            if not msg_ids:
                continue
            # Bit 0 of UserMessage.flags is "read" (see AbstractUserMessage.ALL_FLAGS).
            total += UserMessage.objects.filter(message_id__in=msg_ids).update(
                flags=F("flags").bitor(1)
            )
    print(
        f"marked {total} usermessage rows read for stream={stream_name!r} topic={topic_name!r}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
