# Messaging

Private conversations between a few people, each message readable only by the people in it. Unlike the chat and the forum, the messages are **not records**: they never go on the chain. The chain's part is to say whose keys are whose, and which are current. See **App** in [../glossary.md](../glossary.md).

## What the chain provides

- **Encryption keys.** Each account that wants messages publishes an X25519 key as `epubkey` on its identity declaration. The current one is the one on the latest declaration the reader's history holds. See [../identity.md](../identity.md) for where it comes from.
- **Signing keys.** A sender signs each message with its working key, and recipients check that signature against the sender's current keys on the chain.
- **Disputes.** A message from an account that is disputed, as seen by the recipient's history, is shown as unverified until the dispute is settled.

How messages travel and where they wait until read is between servers and clients, and the chain has no part in it.

## Sending a message

Bob writes to Charlie and Dave.

1. Bob checks on the chain that Charlie and Dave each have an encryption key and are not disputed.
2. He picks a random message key and encrypts the message once with it.
3. He wraps the message key for each recipient's encryption key, and for his own so that he can read it back: one ephemeral X25519 key for the message, an X25519 agreement with each recipient's key, HKDF, and the message key encrypted under the result.
4. He signs the ciphertext, the list of recipients and their wrapped keys together with his working key.

Charlie unwraps his copy of the message key, decrypts, and checks Bob's signature. The signature covers the recipient list as well as the ciphertext, because every recipient holds the message key: without it, Charlie could encrypt something else under that key, keep Bob's wrapped key for Dave, and Dave would read it as Bob's.

## Conversations

A conversation is whoever the latest message was sent to. There is no group to set up or keep in order: adding someone means wrapping for them from the next message on, and removing someone means no longer wrapping for them. Two people changing the membership at the same moment cannot fork anything, because there is nothing shared to fork.

Each recipient adds roughly 100 bytes to a message, and the sender checks one more account on the chain. Neither is a limit worth enforcing: a conversation of fifty is a few kilobytes of overhead. The app may still cap conversation size to keep them conversations rather than broadcasts; that is a choice for the client, not a rule.

## What it does not do

- **Forward secrecy.** Keys come from the seed and do not rotate, so a leaked seed opens every message ever sent to that account by anyone who kept a copy. This is for casual use, not for people being targeted.
- **Hide who talks to whom from the server** that carries the messages. Keeping messages off the chain keeps that from the rest of the world.
- **Delete.** A message sent cannot be unsent; only the recipients' copies can be discarded.

## Not built yet

All of it.
