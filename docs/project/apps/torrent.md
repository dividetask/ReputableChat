# Torrent

A catalogue of torrents: what is offered, who offered it, and what people who fetched it thought of it. Its records carry `torrent` as the further part of their type: `reputablechat:message:v0.001:torrent`. The chain ignores that part; this document says what the torrent app does with it. See **App** in [../glossary.md](../glossary.md).

Nothing here needs a change to the rules or to [../chain.md](../chain.md). The bytes of a torrent never go on the chain or through the agnostic server. The chain carries the part a tracker site carries today, the listing and what people say about it, and the swarm stays BitTorrent's.

## Why it fits

A public tracker site has two problems the chain already answers.

- **Fakes and malware.** A site fights them with uploader badges handed out by its staff. Here an account nobody has vouched for sits at exactly zero and is invisible, so a thousand accounts listing a fake are a thousand listings nobody sees. Whose listings are worth seeing is each viewer's own reputation, not a badge.
- **The site going away.** A listing is a signed record held by every server, so the catalogue outlives any one of them, and a server cannot drop a listing that others have acknowledged without the gap showing.

## What a torrent is

A message whose type carries `torrent` and which has no target. It must carry a `file`, and the first file is the torrent's **info dictionary**.

A BitTorrent v2 infohash is the SHA-256 of the bencoded info dictionary. That is exactly how the rules name a file, so the infohash *is* the file's name: `file: ["<infohash>.info"]`. Any BitTorrent v2 client can join the swarm from it, and a client that holds those bytes can check them against the record without trusting whoever served them. `.torrent` is not usable as the extension, since the rules allow at most five characters.

Only v2 and hybrid torrents can be listed. A v1-only torrent is named by SHA-1, which is not a File.

| field | in a torrent |
|---|---|
| `title` | its name |
| `body` | its description, as text |
| `file` | the info dictionary first; any further files are images shown with the description |
| `url` | optional: a magnet link. The client builds one from the infohash when it is absent, and shows a present one only if it names the same infohash |
| `lang` | the language of the content, so a reader can hide what they do not read |

## Replies, votes and labels

- **A message with a target** is a reply to the torrent it names, as a forum message with a target is.
- **Reactions** whose type carries `torrent` are votes on what the torrent turned out to be: `+` for it was what it said, `-` for it was not. They count towards the voter's rating of whoever listed it, exactly as chat reactions do: there is one reputation, shared by every app. A `-` sinks whoever listed a fake for everyone who trusts the voter.
- **Reactions with no app** are labels meant for every app, and do not move a rating.

## Withdrawing a torrent

A record cannot be removed. A notice of kind `withdrawn`, typed `:torrent`, targeting the account's own torrent, makes clients stop listing it, and is honoured only from the account that listed it. The forum's edits and retractions are to work the same way, and need no rules change either.

## The torrent server

An app beside the agnostic server, one per server, as the chat is.

- **Indexes listings.** It reads `GET /api/records?type=reputablechat:message:v0.001:torrent` and the replies, reactions and notices around them, and offers search. It computes no reputation: the client asks for candidates and decides what to show, by its own viewer's buckets.
- **Holds info dictionaries**, and fetches one it lacks from the torrent servers that announced themselves, the way the chat fetches files: a `service` notice typed `:torrent` carrying its address, and nudges to the agnostic server by whether those servers have what they are asked for.
- **Passes its users' records on** to the agnostic server on the local listener, holding them to its own terms first: an info dictionary that parses as BitTorrent v2, a size cap on it.

What it does **not** do by default is take part in a swarm: no tracker, no web seed. Each of those is the operator's to switch on, since they put the content itself on the operator's machine.

## What it acknowledges

Everything, whatever its app, as in [chat.md](chat.md).

## Things worth knowing before building it

- **Votes are public.** A `+` says, under the voter's account, that they fetched the torrent. Downloading leaves nothing on the chain; voting does.
- **The swarm sees addresses.** The chain links an account to its listings, and BitTorrent links an address to what it fetches. The app does not hide either.
- **A listing is permanent.** Withdrawing hides it from honest clients, but the record, and the infohash in it, stay on every server that holds the chain. See the open question below.

## Open questions

- **What every server's heartbeat anchors.** The agnostic server's heartbeats acknowledge every record of the version, whoever wrote it and whatever app it is for, so every server's host account anchors every listing. That is right for a chat and may not be for a catalogue an operator could be held answerable for. Letting a server leave some records out of its heartbeats is a change to the server, not to the chain: the rules already leave what to acknowledge to whoever signs.
- **Native transfer.** Serving the pieces between torrent servers over HTTP, as the chat shares files, would drop the dependency on BitTorrent and keep files inside the reputation system. It costs a protocol of our own and gives up every existing client.

## Not built yet

All of it.
