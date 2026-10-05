# Currency

What a server does with currency. Any account can also be a currency. The rules say how an account becomes one, how currency moves and who settles a double spend; see section 9 of [../rules/v0.001.md](../rules/v0.001.md). This document says what a server is expected to use it for. Unlike the chat and the forum, currency is not named by a further part of a record's type: a `transfer` can ride on a record of any type and any app.

## What it is, and what it is not

Arcade tokens, casino chips, Disney Bucks. A server issues a currency, sells it for money off the chain, and takes it back in return for what the server provides. It is not an investment and is not meant to hold value: people are expected to buy what they will use soon, and an issuer may retire its currency whenever it likes, the way an arcade changes its tokens.

The trust model is the arcade's. The issuer decides which of two conflicting spends stands, it can issue as much as it likes, and it can stop honouring its currency at any time. Nothing on the chain prevents any of that. What the chain does is make it visible: every issue, spend and choice is signed, and an issuer that double spends its own outputs makes its own account disputed, for everyone to see.

## Which account issues it

A server makes an account a currency by giving it an identity declaration, its first or a later one, that carries a transfer of its own currency; usually the first handful of tokens it sells. From then on it holds an unlimited amount of its own currency and can issue in any record it signs. That account also signs every choice between double spends, and must never sign records none of which saw the others, or it disputes itself. So the issuer should be an account driven by one program, not an account people also chat from. It can be the host account on a quiet server, or an account of its own.

The issuer's handle is the currency's name, its avatar the currency's picture, and its bio is the place to say what the currency buys and at what price.

## Charging for records

A server can refuse to store records its own users submit unless they pay, in the same record, with a `transfer` to the issuer. A message paying a fee is one record, not two. What a record costs is the server's choice.

What comes back is the issuer's to reuse. Most issuers are expected to hand returned tokens out again rather than destroy them, so a currency can run for years without issuing more than it started with. Destroying is there for anyone who wants it, as a transfer with no `out`.

This is a limit on what a server spends, not a defence of the network. A record does not say which server it came in through, and servers are expected to store records that arrive from other servers whether or not they paid anybody, or at least their record hashes, so that walking the chain still works. Someone unwilling to pay can post through a cheaper server. Keeping unvouched-for accounts out is still reputation's job.

## Charging for the vault

A vault is stored by one server and never replicated, so charging for it is a lever that cannot be routed around by posting elsewhere. A vault is not a record and cannot carry a `transfer`, so the payment is a separate record from time to time.

The friend list lives in the vault. A server that stops being paid should stop accepting new versions of it, not stop serving the last one: letting somebody keep and move their own vault is the difference between an arcade and a ransom.

## Rate limiting

A server can hand each account a token and replace it some time after it is spent, which limits how fast anyone posts. Doing it on the chain costs a record for every token handed out. A counter in the server's own database does the same job for nothing, so the chain is only worth it where somebody other than the server needs to check.

Handing tokens to every account invites people to make accounts to collect them. Handing them only to accounts the issuer can see, rated above zero, lets reputation do the sybil defence it already does.

## Double spends

An output can be spent once in any one history. Two records from one account spending the same output, neither acknowledging the other, is a double spend. It makes the spender's account disputed, and neither spend takes effect until the currency's issuer endorses one. A server accepting a payment is usually the issuer itself, so it knows at once which spend it has chosen.

The spender's account stays disputed until its adjudicators post a quorum. Its keys are not assumed stolen: the quorum lets it carry on with the keys it had. Deciding which spend stands is the issuer's, because the spender's own adjudicators are the spender's choice; deciding whether the account carries on is the adjudicators', as it is for any disputed account. That holds when the issuer double spends too: its own adjudicators settle its dispute, and once they have, the issuer chooses which of its spends stands.

## IOUs

Any account can become a currency, so a person can too, with a later identity declaration: an IOU is a transfer of your own currency to whoever you owe, and paying it back is them sending it back to you. The chain makes no promise that it will be.

## Not built yet

All of it. No client or server reads `transfer` yet.
