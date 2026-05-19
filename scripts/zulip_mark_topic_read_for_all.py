"""Mark every UserMessage row for a Zulip (stream, topic) read for all subscribers.

Designed to be exec'd inside `manage.py shell` so the Zulip venv + Django
settings are already wired. Arguments come in via environment variables to
sidestep nested shell quoting around Unicode/space-bearing topic names.

Required env:
  ZULIP_STREAM_ARG — stream name (e.g. "monitoring")
  ZULIP_TOPIC_ARG  — topic name (e.g. "slopgate" or "✔ slopgate")

Marks both TOPIC and the resolved counterpart ("✔ TOPIC") so the caller
can resolve-then-mark or mark-then-resolve without worrying about order.

Bit 0 of UserMessage.flags is "read" — see AbstractUserMessage.ALL_FLAGS
in Zulip's zerver/models/usermessage.py.
"""
import os

from django.db.models import F

from zerver.models import Message, Recipient, Stream, UserMessage

stream_name = os.environ.get("ZULIP_STREAM_ARG", "")
topic_name = os.environ.get("ZULIP_TOPIC_ARG", "")
if not stream_name or not topic_name:
    raise SystemExit("ZULIP_STREAM_ARG and ZULIP_TOPIC_ARG must be set")

subjects = [topic_name]
if not topic_name.startswith("✔ "):
    subjects.append(f"✔ {topic_name}")

streams = list(Stream.objects.filter(name=stream_name))
if not streams:
    raise SystemExit(f"stream not found: {stream_name}")

total = 0
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
        total += UserMessage.objects.filter(message_id__in=msg_ids).update(
            flags=F("flags").bitor(1)
        )
print(
    f"marked {total} usermessage rows read for stream={stream_name!r} topic={topic_name!r}"
)
