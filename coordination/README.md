# Coordination

How the agnostic server and the apps ask each other for things. Every branch
merges this folder, so a request written on one branch reaches the others at
their next merge.

## Requests

One file per request, addressed to whoever must act on it:

```
coordination/requests/<to>/<from>-<short-name>.md
```

`<to>` and `<from>` are `server` or an app's directory name (`chat`). A
request says:

- **Why**: what the asker cannot do without it.
- **What to change**: concrete enough to build from.
- **How the asker will use it**, so the one acting can tell a better way
  when there is one.

Write a request on your own branch. The one it is addressed to edits it to
answer a question or narrow it, and **deletes it once it has landed**,
saying so in the commit message. A request that turns out not to be wanted
is deleted by the asker. Nothing is kept once done: the history is in git.

A change another side must follow -- anything listed under "What the apps
depend on" in [server/CLAUDE.md](../server/CLAUDE.md), say -- gets a
`COMPATIBILITY:` paragraph in the commit message and a request to each side
it affects, telling it what changed and what to do.

## Todos

`todo/<side>.md`: what one side means to do next that nobody asked for.
Each side edits only its own.
