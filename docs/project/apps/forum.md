# Forum

The forum app, a threaded discussion board. Its records carry `forum` as the further part of their type: `reputablechat:message:v0.001:forum`. The chain ignores that part; this document says what the forum app does with it. See **App** in [../glossary.md](../glossary.md).

## Posts and comments

There is one kind of record for both: a message whose type carries `forum`.

- A message **without a target** is a post. It is expected to carry a `title`.
- A message **with a target** is a comment on the forum message it names. A comment on a comment belongs to the post its targets lead back to.

`url`, `file` and `lang` are shown when present. A url is shown as a link only for schemes the client accepts, and as plain text otherwise; the client never fetches it to build a preview. `lang` lets a reader hide posts in languages they do not read.

## Votes and labels

- **Reactions** whose type carries `forum` are votes. They count towards the author's rating of whoever wrote the record they target, exactly as chat reactions do: there is one reputation, shared by every app.
- **Reactions with no app** are labels meant for every app, and do not move a rating.

## What it shows and ignores

Messages, reactions and notices whose type carries `forum`, and notices with no app. Records of other apps are not shown, and a forum record that targets another app's record is ignored.

## What it acknowledges

Everything, whatever its app, as in [chat.md](chat.md).

## Not built yet

- **Boards.** The first version is one board. Boards are to work as the chat app's rooms do, once those exist.
- **Edits and retractions.** Expected to be notices of a kind this app defines, targeting the original and honoured only from the same account. No rules change is needed.
