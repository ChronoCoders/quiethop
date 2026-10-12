# QuietHop

B2B onion routing with cryptographic access control and residential exit IPs.

## What it is

QuietHop carries outbound HTTP and HTTPS through three relay hops and out of a
residential IP. At the network level the destination sees a residential address
and nothing that points back to your company: not your address space, not your
hostnames.

What travels inside the request is yours to control. Headers, cookies, tokens and
the TLS fingerprint of your own HTTP client pass end to end, so a destination
that reads them can still recognise you. QuietHop changes where a request comes
from and nothing about what it carries.

Access is gated by a blind-signed token. A relay checks that a request carries a
token the authority signed, without learning which subscriber sent it, because
the check is arithmetic on the token against a pinned authority key and needs no
call home.

Built for workloads such as ad verification, brand-safety crawling, pricing
intelligence, fraud probes and security research, and any traffic that has to
leave from somewhere other than your corporate address space.

## How a circuit is built

1. The client signs in to the authority and asks for a blind-signed token. The
   authority signs without seeing the token value. What it keeps is a per
   subscriber issuance counter and a row holding a subscriber id and a timestamp.
2. The client fetches the signed relay registry and picks its own three hops. The
   authority has no endpoint that assigns a path, and the table that once
   recorded assignments has been dropped.
3. The client dials the guard at the address the registry publishes for it and
   runs one Noise NK handshake per hop, nested through the hops already built,
   so each relay holds a session key for its own hop only.
4. The exit checks the destination port against an allowlist and dials out
   through a residential proxy provider's SOCKS5 exit.

The path rules the client applies are distinct relays, always distinct hosts, and
never two hops inside one IPv4 /16 or one IPv6 /32. Operator diversity is a
client setting rather than a registry claim, and it is off by default while one
operator runs every relay.

## Privacy model

Three principals see different slices of a request.

**Authority.** Knows who you are, because you sign in with an account tied to
your subscription. It signs your token blind, stores no token value, and neither
chooses nor records which relays you use.

**Relay.** Knows that a token carried a valid signature and had not been seen
before, plus the hop before it and the hop after it. The signature check runs
before the replay check and both must pass. A relay reads no database and shares
no state with any other relay.

**Exit.** Sees the destination host and the innermost plaintext. It does not see
your address.

What holds today. At the network level the destination cannot attribute the
request to you, which is the property the design is built around. A relay on its
own, without the authority's records, cannot say which subscriber it is
carrying.

What does not hold today. Distributed Systems Labs, LLC runs the authority and
all three relays. That party sees your address when you sign in and again when
your client reaches the guard, and it can match the two. No cryptography
prevents that, so at this stage the service makes no claim of unlinkability
against us.

The protocol is designed so that relays can be run by independent operators
instead of by one party. Today one party runs all three hops, and no third party
operates a relay.

Spreading the hops raises the bar without removing the central limit of onion
routing. A guard and an exit run by the same party, or cooperating, can link a
client to its destinations: the guard sees the client's address, the exit sees
the destination, and the timing and volume of what they both carry match a
circuit up without the middle hop and without breaking any encryption. Tor's own
design paper puts that attack among its non-goals. Hops at three operators mean
such a pair has to collude rather than read two of its own tables, which is a
higher bar and not a guarantee.

A circuit built through the SDK reports how many distinct operators it crossed,
so an SDK caller can see which bar a given circuit clears. The SOCKS5 daemon
does not surface that count today.

## Architecture

| Component        | Role                                                             |
|------------------|------------------------------------------------------------------|
| Authority        | Go service. Subscriber sign-in, blind token signing, the signed  |
|                  | relay registry, the dashboard API. PostgreSQL is its only store. |
| Guard relay      | First hop. Verifies the blind token, terminates the client's     |
|                  | TLS, and forwards to the middle relay named in the registry.     |
| Middle relay     | Second hop. Moves opaque bytes between guard and exit.           |
| Exit relay       | Third hop. Peels the innermost layer, checks the port, and dials |
|                  | through the residential SOCKS5 address.                          |
| Residential exit | A residential proxy provider's address, which is the one the     |
|                  | destination sees.                                                |
| Dashboard        | Next.js operator console for the subscription and its usage.     |

Every hop terminates TLS with a real Let's Encrypt certificate obtained over
TLS-ALPN-01, and a challenge connection is routed away from the circuit handler
by peeking at the ClientHello. A relay takes its listening port from its own
`RELAY_PORT`. Traffic between relays is TLS as well, with the server name taken
from the registry entry and no skip-verify path anywhere, so an observer of one
hop sees TLS to a QuietHop hostname.

One TLS link between two relays carries many circuits at once. The writer takes
one frame from one circuit per turn, so a circuit with a backlog cannot hold the
link, and each circuit has its own flow-control window that opens again as the
far end acknowledges delivery.

## Client integration

The product surface is a SOCKS5 daemon and a Rust SDK.

1. Sign up through the dashboard and wait for approval. Approval is manual.
2. There is no key to copy. Give the daemon your subscriber credentials in
   `AUTHORITY_URL`, `CLIENT_EMAIL` and `CLIENT_PASSWORD`, and it signs in and
   obtains tokens itself. `SOCKS5_BIND` sets the local listener, which defaults
   to 127.0.0.1:1080.
3. Point your HTTP client at that local endpoint. Each outbound request travels
   a three-hop circuit and leaves from a residential IP.

The SDK is available for applications that prefer to build circuits in process.

## Stack

- **Authority**: Go, minimum language version 1.25.0 with the toolchain pinned
  at go1.27.2, PostgreSQL, Argon2id password hashing, HS256 JWT sessions
- **Relay**: Rust 2021, tokio, rustls, rustls-acme, tokio-socks, num-bigint for
  the blind token check
- **Shared wire protocol**: Rust, Noise NK over X25519 with ChaChaPoly and
  SHA-256
- **Client SDK and daemon**: Rust, tokio, rustls
- **Dashboard**: Next.js 15 App Router with React 19, calling the authority
  through server-side rewrites so the browser never addresses it directly

## Self-hosting

Not supported. QuietHop runs as managed infrastructure. The authority, the relay
fleet, the residential exits and the certificate lifecycle are operated by
Distributed Systems Labs, LLC, and the protocol leaves room for other operators
to run relays later. The repository is public so that the protocol can be read
and reviewed, which is not the same as a licence to run it; the licence section
below says what production use is granted.

## Security model

The specification that defines the primitives, the principals and their trust
boundaries, the token protocol step by step, and what the system does not protect
against is not published.

For vulnerability disclosure, see [SECURITY.md](SECURITY.md).

## License

Business Source License 1.1, copyright 2026 Distributed Systems Labs, LLC. The
Change Date is 2029-05-23, after which the Licensed Work converts to the Apache
License, Version 2.0.

Production use is not granted, with one exception that the Additional Use Grant
in the licence spells out: a subscriber may run the client components, the
`quiethop-client` daemon and the `quiethop-client-sdk` crate, in production to
connect to the QuietHop service while the subscription is active. The grant
reaches whatever those components depend on, which today is `quiethop-crypto`,
when it runs as part of them. It reaches no further, so a relay and the
authority stay non-production use even though they share crates with the
client. Everything else stays non-production use until the Change Date. See
[LICENSE](LICENSE) for the terms.

October 2026
