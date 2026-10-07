# Chat

The chat app. Its records carry `chat` as the further part of their type: `reputablechat:message:v0.001:chat`. The chain ignores that part; this document says what the chat app does with it. See **App** in [../glossary.md](../glossary.md).

## What it shows

- **Messages** whose type carries `chat`. A message without a target is said to the room; one with a target replies to it. Messages with any other app, or with none, are not shown.
- **Reactions** whose type carries `chat`, on the records they target. These count towards the author's rating of whoever they react to.
- **Reactions with no app** are meant for every app. The chat app may show them as labels, such as a mark that a message was made by AI, and they do not move a rating.
- **Notices** whose type carries `chat` or no app.

A chat record that targets another app's record, or a record of another app that targets a chat one, is ignored.

## What it acknowledges

Everything, whatever its app. The server verifies every app's records and offers them to chat clients as records to acknowledge, and a client picks among them by their authors' reputation as it does for its own. Showing a record and acknowledging it are separate decisions; see **Walking the chain is reputation-blind** in [../chain.md](../chain.md).

## Not built yet

Rooms. When they are, the forum's boards are to work the same way.
