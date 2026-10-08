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
payload:   {"ack":["141159713d19cb233902ed9a22b0e9fdb2b7a22118515bf865cb7df5dac85ef5"],"body":"","id":"4e9e1268fac1f495649795d556208d5f4bcfbb29a7c8ff258e0e5106ceb3881e","pubkey":"kGG17NiNWujZki2cS5D2SAm5B4AYvbNxB1DlAbWY9dU","ts":1790202880,"type":"reputablechat:heartbeat:v0.001"}
signature: GxhVQvejUeIzo6bnIuxO0Yd8QcfuvwzJReW4Kb9fs9-hP4PIpjul0AvigIurmKL7VTSX_i5O7fqnkA-1IFW1Cw
hash:      0a671e7d67ecdc4e5c1a3c47c2e083da582b2e85e0f24fc517554ae0bdd1ab6f
```

## unsorted

A record whose ack is in descending order, where the rules require it sorted.

Signed with: alice.

```
payload:   {"ack":["d878b8a4cd35b3f9e4cd8d3e2387bb72069932bfc88d173a9928bf25b245e319","ba0cfeccca684cdcfbeb504a44081c6427cb82f87b48368142e7b35fc6f88304","9cfb8f2736c9fbb60c5ed3e1473a347a8670bf5e7a21d8be99e97f4fca560c9e","35eb6dbc4b059cc10208d29b6fa3025fbd40930a22881bdc3480b957704b320a","1045791a572033f818385541136a28cf55fc5eb69639c038f771d8c4f61b0d85"],"body":"Hello.","id":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","pubkey":"s4QVXvEpTj_ZBxXLun1A-tCxqIDhRvU1URnZZRHnYLE","ts":1790203300,"type":"reputablechat:message:v0.001"}
signature: 9mWIHNaTeHupyH5Jq-NmluJSXKi56tsGFWjWuvwl6eBHYEcLoKts8BpAaJa_R8NvcQ8ANMQjbcren4BPT7C-DA
hash:      01d0d6b1a393c17b6a827f2d687b7c958c817559602bf86fb1210da464a30ba2
```

## unbalanced

A transfer that spends 99 and makes 98, where the rules require them to add up.

Signed with: alice.

```
payload:   {"ack":["ba0cfeccca684cdcfbeb504a44081c6427cb82f87b48368142e7b35fc6f88304"],"body":"Short change.","id":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","pubkey":"s4QVXvEpTj_ZBxXLun1A-tCxqIDhRvU1URnZZRHnYLE","transfer":{"currency":"19af977b6e8526be8ebba8befe5f0f5a1a61f12ba8d16ec061b92dfa039fc3b7","in":["9cb36d78ddfb7109be6c630690a9c1f3dc908a78008403648ba166c09d6ae489"],"out":[{"to":"24b3ad1b57c22ed2383abd0c6f3d8160f636bcc65965418ff8a3e0dcb2abc3b5","value":"98"}]},"ts":1790203360,"type":"reputablechat:message:v0.001"}
signature: RqDev8c6LgvKZCYKcOc7GPJEvjSJ7kMvHUAHCOH6KKyN1CQejEMQjKzLhiQU0a2RP4bLooDTdmTVfq1b3ENBCA
hash:      41e0808089ee14a09ea46fa34802ec6946439249a27d3e5900f6c9fe5e781372
```
