"""Mark every UserMessage row for a Zulip (stream, topic) read for all subscribers.

Designed to be exec'd inside `manage.py shell` so the Zulip venv + Django
settings are already wired. Arguments come in via environment variables to
sidestep nested shell quoting around Unicode/space-bearing topic names.

Required env:
  ZULIP_STREAM_ARG — stream name (e.g. "monitoring")
  ZULIP_TOPIC_ARG  — topic name (e.g. "slopgate" or "✔ slopgate")

Marks both TOPIC and the resolved counterpart ("✔ TOPIC") so the caller
can resolve-then-mark or mark-then-resolve without worrying about order.

Uses Zulip's canonical `do_update_message_flags` action per affected
user so the matching `update_message_flags` realtime event fires for
every client — a raw ORM update would flip the DB bit but leave open
Zulip sessions still showing the messages as unread until reload.
"""
import os

from zerver.actions.message_flags import do_update_message_flags
from zerver.models import Message, Recipient, Stream, UserMessage, UserProfile

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

# Collect every message id in the union of subject variants.
msg_ids: list[int] = []
for stream in streams:
    try:
        recipient = Recipient.objects.get(type=Recipient.STREAM, type_id=stream.id)
    except Recipient.DoesNotExist:
        continue
    msg_ids.extend(
        Message.objects.filter(recipient=recipient, subject__in=subjects)
        .values_list("id", flat=True)
    )

if not msg_ids:
    print(f"marked 0 rows: no messages for stream={stream_name!r} topic={topic_name!r}")
    raise SystemExit(0)

# Every user that has any UserMessage row for these messages. We don't
# filter on the read flag — even when the DB already shows read=1 (e.g.
# a prior raw ORM update outside Zulip's action layer), the user's
# clients may still be displaying unread because no
# `update_message_flags` event was ever emitted. Calling
# do_update_message_flags emits the event unconditionally, so existing
# sessions reconcile on the next tornado push.
user_ids = list(
    UserMessage.objects.filter(message_id__in=msg_ids)
    .values_list("user_profile_id", flat=True)
    .distinct()
)

total_users = 0
total_rows = 0
for uid in user_ids:
    try:
        user = UserProfile.objects.get(id=uid)
    except UserProfile.DoesNotExist:
        continue
    their_msgs = list(
        UserMessage.objects.filter(user_profile_id=uid, message_id__in=msg_ids)
        .values_list("message_id", flat=True)
    )
    if not their_msgs:
        continue
    # do_update_message_flags performs the bulk flag flip AND emits the
    # update_message_flags event onto each user's tornado queue so open
    # clients clear the unread count immediately. The return value is
    # the count of rows actually flipped (0 if already read), but the
    # event fires either way.
    do_update_message_flags(user, "add", "read", their_msgs)
    total_users += 1
    total_rows += len(their_msgs)

print(
    f"marked {total_rows} usermessage rows read across {total_users} users "
    f"for stream={stream_name!r} topic={topic_name!r}"
)
