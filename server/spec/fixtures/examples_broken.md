# Records that break a rule, signed correctly

Appended to the example chain by spec/examples_spec.rb, which asserts that the
checker rejects every one of them. Signed with the real example keys, so the
signature and hash checks pass and the rule checks are what has to catch them.
A checker that quietly stopped looking would pass this file, and the spec would
then fail rather than going green on nothing.

## early

A heartbeat 60 seconds after its author's previous one, where the rules set a floor of 480.

Signed with: server.

```
payload:   {"ack":["a4986de4f72aea0879142f6bf395eafc14ddf3dccaae6798a1ce55e4c23cf1fc"],"body":"","id":"7e7d7c1081323cbef65c790c4d7e99d19e936aa6e4d3dfcf271f2a71e253522a","pubkey":"kGG17NiNWujZki2cS5D2SAm5B4AYvbNxB1DlAbWY9dU","ts":1790202880,"type":"reputablechat:heartbeat:v0.001"}
signature: mAwQlfojs01av3-pQtR0Yjps-qOaxzuE4zbVw0DD0KxwrppZPwqQyg_f717YjEvU8J6ZrQQMJ8bszwbpwTGLBw
hash:      4d961f6c8ba7a91fe44aa421980bca45de667aebb16f6e8c48b5b7f5db4d153e
```

## unsorted

A record whose ack is in descending order, where the rules require it sorted.

Signed with: alice-recovered.

```
payload:   {"ack":["d878b8a4cd35b3f9e4cd8d3e2387bb72069932bfc88d173a9928bf25b245e319","f09f976106f8f643f61cb829921cc0e41cb16e20dea1ded6d560e369509a283d","20a0f92655878ead9322ffebb2b6d694cc6bfb777bebbe17564cc4a79ef6c87a","35eb6dbc4b059cc10208d29b6fa3025fbd40930a22881bdc3480b957704b320a","1045791a572033f818385541136a28cf55fc5eb69639c038f771d8c4f61b0d85"],"body":"Hello.","id":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","pubkey":"s4QVXvEpTj_ZBxXLun1A-tCxqIDhRvU1URnZZRHnYLE","ts":1790203300,"type":"reputablechat:message:v0.001"}
signature: t_X73x-41ocDxjbRq_GwYepq6xAw2yQUr-ccMf7HyqvLSoWNqdhVhzXtRTg-WmkvDv48ZI8zb83lAy6cUveeCw
hash:      5e8861864b41ff73789afabb0f1e4f2e1c7c71a1a2b050c90764f0e521d9238c
```

## unbalanced

A transfer that spends 99 and makes 98, where the rules require them to add up.

Signed with: alice-recovered.

```
payload:   {"ack":["f09f976106f8f643f61cb829921cc0e41cb16e20dea1ded6d560e369509a283d"],"body":"Short change.","id":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","pubkey":"s4QVXvEpTj_ZBxXLun1A-tCxqIDhRvU1URnZZRHnYLE","transfer":{"currency":"8350570cde5a6695b11f98084b3777ab385ef1eb10125b9c12d718737c730260","in":["3e886f60d563df5cd2a01a0112344d2088b035d312457276b62869a07683dc8e"],"out":[{"to":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","value":"98"}]},"ts":1790203360,"type":"reputablechat:message:v0.001"}
signature: 08LU_w5goSejWKb70j9qpqMANU7v7I3i0artOaiAItOktAAmF_LFZ5DHhF-WJCHP4_RYMzjvFpGBRemh0PMhDg
hash:      fa54c4a69ab25d1f30a985e51ef6215cd476b397d992319755cc0b1f94035396
```
