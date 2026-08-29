# pathrot

**Your uploads keep failing with `ECONNRESET`, and every tool says the network is fine.
There are two very different reasons for that, and they need opposite fixes.**

| | what goes wrong | the fix |
| --- | --- | --- |
| **DNS detour** | your resolver hands you a CDN edge on the wrong continent, so every packet crosses far more of the internet than it should | fix your resolver |
| **path MTU blackhole** | large packets are **dropped**, silently, with no ICMP back | lower your MTU |
| **path corruption** | large packets are **altered**, and TCP cannot tell | tunnel out |

The fixes do not transfer. Lowering the MTU does nothing for corruption; tunnelling masks
both of the last two while costing bandwidth; and if your DNS is wrong, everything you
measure afterwards is a path you should not be on at all. Guessing between them is how
people lose days to this.

pathrot checks all three and tells you which one you have.

```
$ pathrot

[1/8] DNS — is your resolver sending you somewhere sensible?
  resolvers: 1.1.1.1 8.8.8.8
  ok  api.anthropic.com -> 160.79.104.10 (9ms)

[2/8] baseline — is the endpoint usable at all?
  ok  tcp 9ms · tls 22ms · download 14.2 MB/s · endpoint accepts full uploads

[3/8] path MTU — are large packets being dropped outright?
  ok  path MTU 1500 on en0 (interface 1500) — no blackhole

[4/8] full-speed uploads → is anything damaging them?
  primary   ..!.!..!.!!.  5/12 failed

  5/12 failed (41%) — 5 with a TLS integrity error
...
verdict  this path is corrupting your uploads
```

---

## The symptom

Your connection looks perfect. DNS resolves, TCP connects in single-digit milliseconds,
the TLS handshake completes, small requests return instantly, downloads run at full speed.

And yet:

- `curl` on a large upload dies with `SSL_read: ... sslv3 alert bad record mac`
- Node/Go/Python HTTP clients report `ECONNRESET` — "socket hang up", "connection reset by peer"
- Anything pushing a big request body — an API call with a large payload, `git push`, a file
  upload, a long agent session — fails intermittently and unpredictably
- Small requests to the *same host* keep working, so every diagnostic says "the network is fine"

The failure rate is usually between 10% and 70%, and it drifts over hours. That
intermittency is what makes it so hard to pin down: by the time you go looking, it works.

## Why your tools miss it

| Tool | Measures | Why it can't decide this |
| --- | --- | --- |
| `ping`, `mtr` | loss, latency | small packets; a blackhole only eats big ones, and loss ≠ alteration |
| `iperf`, speed tests | throughput, retransmits | never verifies the payload |
| packet capture + checksum validation | checksums in the trace | on the sending host the checksum field is usually still empty — the NIC fills it in later, so captures are full of false alarms |
| file-integrity tools (`cshatag`, FIM) | bytes on disk | wrong layer entirely |
| `tc netem corrupt` | *injects* corruption | the opposite direction |

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/KrisWonka/pathrot/main/pathrot -o /usr/local/bin/pathrot
chmod +x /usr/local/bin/pathrot
pathrot
```

No dependencies beyond `curl`, `ping` and a POSIX shell. macOS and Linux. No root.

```sh
pathrot                              # 12 probes per round, ~18 MB total
pathrot -q                           # quick pass, 6 probes per round
pathrot -n 32                        # sample a longer window (the fault is intermittent)
pathrot --lan-peer krix@192.168.1.1  # also clear (or convict) your own NIC
pathrot --json                       # machine-readable, for scripting
```

Exit status: `0` clean · `1` a fault was found · `2` could not run a valid test.

## Three faults, one symptom

**An MTU blackhole** means something on the path cannot carry packets as large as your
interface is emitting, and drops them without sending back the ICMP "fragmentation needed"
that would let your machine adapt. Small packets sail through; a TLS handshake completes;
then the first full-size data segment vanishes. This is common — VPN encapsulation, PPPoE
and some consumer routers all cause it — and it is the fix people usually stumble onto, by
setting their MTU to 1492, 1460 or 1400 until things start working.

**Path corruption** means the bytes arrive, but not the bytes you sent. This one is rarer
and much less known, because TCP is supposed to make it impossible — see below.

**A DNS detour** is upstream of both. If your resolver is in the wrong part of the world it
will answer CDN hostnames with edges near *itself*, not near you, and your traffic then
crosses far more of the internet than it needs to — more hops, more middleboxes, more
opportunity for either of the other two faults to bite. It is easy to miss because DNS
resolution itself keeps working perfectly; only the destination is wrong.

They look identical from the application. pathrot separates them by measuring the path MTU
directly (round 2) and by reading *how* the uploads die (round 3): a dropped packet
eventually surfaces as a stall or a reset, while an altered one makes TLS reject a record's
authentication tag — which is proof of alteration, and cannot be caused by loss.

## How it works

No special server is needed. TLS already contains a perfect corruption detector: every
record carries a 128-bit authentication tag, so altering one bit in flight makes the
receiver reject it. pathrot drives a large HTTPS upload and reads the failure.

The value is the attribution ladder — what turns "something is broken" into "this layer,
this fix".

| Round | What it separates |
| --- | --- |
| 1. DNS | is your resolver even pointing you at a nearby edge? |
| 2. baseline + endpoint check | is the network down, and does the endpoint actually read a whole body? |
| 3. path MTU, from the physical interface | are large packets simply being dropped? |
| 4. full-speed uploads × N | the failure rate, and whether TLS blames integrity |
| 5. same payload, rate-capped | burst-triggered, or constant? |
| 6. a second destination | is it just that one server? |
| 7. bound to the physical interface | probes the real link even when a tunnel is masking it |
| 8. LAN-only transfer to a peer | **your own NIC/driver, or something upstream?** |

Round 1 is first for a reason learned the hard way. A machine in Michigan configured with a
public resolver on another continent will be handed CDN edges on that continent, and then
every later measurement describes a path the traffic should never have been on. pathrot
resolves the target with your resolver and with `1.1.1.1`, and compares how long it takes to
reach each answer — no geolocation service, no external dependency. If yours is much further
away, that is reported before anything else, because it invalidates everything after it.

Rounds 2 and 6 both source from the physical interface on purpose. When a tunnel is up the
default route points at the tunnel, whose own MTU is typically 1280 — measure through that
and you will "discover" a blackhole that is really just your VPN. (That cost an hour during
development, so the test suite now guards it.)

Round 7 is usually what closes the case: if a large transfer to a machine on your own LAN
arrives byte-identical, your hardware is exonerated and the damage is upstream.

## Why TCP doesn't catch corruption

Two reasons, and the second is the important one.

**The checksum is weak.** TCP's checksum is 16 bits of one's-complement sum. Roughly 1 in
65,536 corrupted segments happens to produce the same value.

**NAT recomputes it.** A device doing address translation *must* rewrite the IP addresses
and ports, and those fields feed the checksum — so it necessarily recalculates and rewrites
the checksum before forwarding. If that device also damages the payload, the checksum it
writes is computed over the *already-damaged* bytes:

```
device receives packet → damages payload → rewrites addresses → recomputes checksum → forwards
                                                                        ↑
                                       computed over the damaged data, so it is self-consistent
```

The receiver validates it and finds nothing wrong. Interface error counters stay at zero on
both ends. From TCP's point of view, nothing happened.

Stone & Partridge measured this in the wild for
[SIGCOMM 2000](https://conferences.sigcomm.org/sigcomm/2000/conf/paper/sigcomm2000-9-1.pdf):
between 1 in 1,100 and 1 in 32,000 packets failed the TCP checksum on real Internet paths.
pathrot reports the per-packet rate it infers, so you can see where your path sits.

## Why TLS dies instead of recovering

TLS detects the damage — and then has no way to fix it.

It sits *above* TCP, and TCP has already acknowledged those bytes and dropped them from its
send buffer, so there is nothing left to retransmit. TLS is also stateful: record sequence
numbers and the key schedule advance together, so a failed authentication means the
integrity of the whole stream is no longer guaranteed. The specification requires
terminating the connection.

One damaged packet in a thousand destroys an entire multi-megabyte upload, over and over.

## Why a tunnel fixes it

Send the same traffic through WireGuard and the corruption does not stop — it stops
mattering.

WireGuard authenticates **every packet**, **below TCP**. A damaged packet fails its Poly1305
tag and is silently discarded. The TCP connection inside the tunnel never sees damaged data
— it sees a packet that never arrived, notices the missing ACK, and retransmits.

**A tunnel does not prevent corruption. It converts corruption into packet loss** — and
packet loss is what TCP has been designed to handle since 1981.

| | direct | through a tunnel |
| --- | --- | --- |
| where integrity is checked | above TCP (TLS) | below TCP (per packet) |
| a damaged packet causes | connection terminated | one packet dropped |
| recoverable? | no — start over | yes — retransmit |
| cost | — | the tunnel's own bandwidth and latency |

The same reasoning is why QUIC/HTTP-3 is naturally immune: it authenticates per packet and
retransmits its own losses, no tunnel required. If your client can speak HTTP/3, try that first.

## Four verdicts

pathrot separates what it can prove from what it can only suspect.

**`corrupting`** — at least one probe died with a TLS integrity error (`bad record mac`,
`decryption failed`, and the equivalents in other libraries). That is proof: the ciphertext
that arrived is not the ciphertext that was sent. Lowering your MTU will not help.

**`dropping`** — probes died, but your TLS library did not name the cause. Corruption
produces this too, since not every stack reports the integrity failure in a greppable way,
and a middlebox can also just send a reset. pathrot says plainly that the cause is
unconfirmed, and ranks the fixes by how often each turns out to be right.

**`mtu_blackhole`** — the path cannot carry packets as large as your interface emits.
Reported even when every upload happens to succeed, because it will bite later.

**a DNS detour** is reported alongside any of the above, and moves to the top of the remedy
list when present. A run with clean uploads is still not reported as clean if your resolver
is sending you the long way round.

A path that only times out is none of these. It is slow, not broken, and pathrot says so
rather than manufacturing a finding.

Proof is counted across every round, not just the first. A run can show nothing but bare
resets at full speed and then catch TLS integrity errors while rate-capped; that still means
alteration, and the verdict says so.

## Limitations

**Read this before trusting a result.**

- **The fault is intermittent.** A clean run does not prove a clean path. In the case that
  prompted this tool the failure rate drifted between 17% and 75% over a single day, with
  clean windows in between. If your application is failing now and pathrot says clean,
  re-run with `-n 32`.
- **Probes cost bandwidth.** The defaults upload roughly 18 MB per run to a public
  speed-test endpoint. Use `-q`, or point `PATHROT_URL` at your own server, on metered
  links. Do not run this on a loop against Cloudflare or httpbin.
- **The DNS round needs `dig`.** Without it that round is skipped and says so.
- **The MTU round needs ICMP.** If echo replies are blocked, pathrot says so and tells you
  to try lowering the MTU by hand rather than guessing.
- **Round 7 needs a peer.** Without `--lan-peer` pathrot cannot rule out your own NIC, and
  will say `not tested` rather than guess.
- **Round 6 is best-effort on Linux.** `curl --interface` sets the source address, which is
  enough to bypass a tunnel on macOS and on Tailscale's default routing, but a WireGuard
  setup using policy routing may still send the probe through the tunnel. Treat a clean
  round 6 on Linux with suspicion.
- **The per-packet estimate is rough.** It assumes a 1448-byte MSS and independent,
  uniformly distributed damage. Real corruption is bursty. Order of magnitude only.
- **Field-tested on one corrupting path.** The ladder was derived from, and validated
  against, a single genuinely corrupting network (~28% failure rate, reproduced from two
  independent machines with different hardware, OS and TLS stacks). Everything else is
  covered by the offline test suite. If pathrot gets your path wrong, that is worth an
  issue — especially a false clean.

## Development

```sh
./test.sh
```

Most tests use the `PATHROT_FAKE` seam — a string of verdict characters (`.` ok, `!`
corrupt, `r` reset, `~` timeout, `i` invalid) replayed in place of real probes — plus
`PATHROT_FAKE_MTU` to inject a path MTU. The suite is deterministic and runs offline.
Two tests do hit the network, to check that pathrot refuses an endpoint which will not read
a whole request body; skip them with `PATHROT_SKIP_NET=1`.

## Prior art and credit

The MTU half of this is folk knowledge that people keep rediscovering the hard way, and
some of that rediscovery is very good. The
[claude-code#5674](https://github.com/anthropics/claude-code/issues/5674) thread has sorted
this symptom into several genuinely distinct causes — missing `SO_KEEPALIVE` in Bun,
HTTP/1.1 connection pool exhaustion in undici, server-side drops of large requests, and two
separate path-MTU blackhole postmortems, one of them over IPv6. Several other people
independently found that setting their MTU to 1492, 1460 or 1450 fixed "impossible"
`ECONNRESET`s, and others that any VPN made the problem vanish.

What I could not find anywhere in those threads is the alteration case — a path that
delivers your bytes changed rather than dropping them — or a way to tell it from the MTU
case, which presents identically and is far more common. That is the gap pathrot fills, and
it is a narrow one: if your MTU round comes back clean and your uploads still fail with a
TLS integrity error, you are in a bucket nobody had named.

- Stone & Partridge, *When the CRC and TCP Checksum Disagree*, SIGCOMM 2000 —
  [PDF](https://conferences.sigcomm.org/sigcomm/2000/conf/paper/sigcomm2000-9-1.pdf)
- [`cshatag`](https://github.com/rfjakob/cshatag) — the same idea applied to data at rest

## License

MIT
