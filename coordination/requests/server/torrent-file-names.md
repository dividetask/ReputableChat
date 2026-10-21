# Limit a File's length, not its extension

From the torrent app.

**Why.** Section 1 of the rules names a file by its SHA-256 and "an
extension of 1 to 5 lowercase letters or digits". Real extensions are
longer, and many have more than one part: `.torrent`, `.tar.gz`,
`.pdf.sig`. The torrent app lists files people share, and cannot name
them as they are. The extension is for the apps to read; the chain checks
nothing about it but its form, so its form need only keep the value
bounded and safe to use as a name.

**What to change.**

- **The rules, section 1, File.** A file is named by the SHA-256 of its
  bytes in hex, a dot, and a name of lowercase letters, digits, dots,
  hyphens and underscores, any number of dots included; the whole at most
  128 bytes. The genesis has not been published, so this edits v0.001 and
  needs a new development genesis.
- **`server/lib/agnostic/formats.rb`**, `FILE`, to match.
- **The examples**: one record in `v0.001-examples.md` naming a file with a
  multi-part extension, and in `server/spec/fixtures/examples_broken.md`
  one over 128 bytes and one holding a character outside the set.
- **A request to the chat**, under `COMPATIBILITY:`, since its file store
  and anything checking file names must accept the longer form.

The character set is a suggestion, not a requirement. It leaves out `/`,
`\`, whitespace and capitals so a file's name can be used as a filename
on any server without escaping, and so one file cannot be listed under
two names differing only in case. If the server would rather allow more,
say so here.

**How the torrent app will use it.** Its listings name the BitTorrent v2
info dictionary as `<infohash>.info`, which fits today, and further files
by their own extensions. See `docs/project/apps/torrent.md` on the torrent
app's branch.
