# pathrot

**Does this network path silently corrupt the bytes you send?**

`ping`, `mtr`, `iperf` and every speed test answer *"did the packet arrive, and how fast?"*
None of them answer *"did my bytes arrive unchanged?"* — because everyone assumes TCP
guarantees that.

On some paths it does not.

```
$ pathrot

[1/6] baseline reachability
  ok  tcp 9ms · tls 22ms · download 14.2 MB/s

[2/6] full-speed uploads → is anything corrupting them?
  primary   ..!.!..!.!!.  5/12 corrupt

  5/12 corrupted (41%) — TLS reported bad record mac
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
- Anything that pushes a big request body — an API call carrying a large payload, `git push`,
  a file upload, a long-running agent session — fails intermittently and unpredictably
- Small requests to the *same host* keep working, so every diagnostic you reach for says
  "the network is fine"

The failure rate is usually somewhere between 10% and 70%, and it drifts over hours.
That intermittency is what makes it so hard to pin down: by the time you go looking, it works.

## Why your tools miss it

| Tool | Measures | Why it can't see this |
| --- | --- | --- |
| `ping`, `mtr` | loss, latency | loss ≠ corruption, and TCP repairs loss on its own |
| `iperf`, speed tests | throughput, retransmits | never verifies the payload |
| packet capture + checksum validation | checksums in the trace | on the sending host the checksum field is usually still empty — the NIC fills it in later, so captures are full of false alarms |
| file-integrity tools (`cshatag`, FIM) | bytes on disk | wrong layer entirely |
| `tc netem corrupt` | *injects* corruption | the opposite direction |

pathrot fills the gap: it establishes whether the path between you and the internet is
altering your data, and then attributes the damage to a layer.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/KrisWonka/pathrot/main/pathrot -o /usr/local/bin/pathrot
chmod +x /usr/local/bin/pathrot
pathrot
```

No dependencies beyond `curl` and a POSIX shell. macOS and Linux. No root required.

```sh
pathrot                              # 12 probes per round, ~18 MB total
pathrot -q                           # quick pass, 6 probes per round
pathrot -n 32                        # sample a longer window (intermittent faults)
pathrot --lan-peer krix@192.168.1.1  # also clear (or convict) your own NIC
pathrot --json                       # machine-readable, for scripting
```

Exit status: `0` clean · `1` corrupting · `2` inconclusive.

## How it works

The clever part is that **no special server is needed**. TLS already contains a perfect
corruption detector: every record carries a 128-bit authentication tag. Alter one bit in
flight and the receiver rejects it. pathrot simply drives a large HTTPS upload and reads
the failure.

The value is not the detection — it is the **attribution ladder**, which is what turns
"something is broken" into "here is which layer, and here is what to do".

| Round | What it separates |
| --- | --- |
| 1. baseline handshake + download | is the network simply down or slow? |
| 2. full-speed uploads × N | measure the corruption rate |
| 3. same payload, rate-capped | burst-triggered, or constant? |
| 4. a second destination | is it just that one server? |
| 5. bound to the physical interface | probes the real link even when a tunnel is masking it |
| 6. LAN-only transfer to a peer | **your own NIC/driver, or something upstream?** |

Round 5 exists because when a tunnel is up, the default route points at the tunnel — probing
normally would measure the tunnel instead of the link underneath. Round 6 is usually the one
that decides the case: if a large transfer to a machine on your own LAN arrives byte-identical,
your hardware is exonerated and the damage is upstream.

## Why TCP doesn't catch it

Two reasons, and the second is the important one.

**The checksum is weak.** TCP's checksum is 16 bits of one's-complement sum. Roughly 1 in
65,536 corrupted segments happens to produce the same value.

**NAT recomputes it.** A device doing address translation *must* rewrite the IP addresses and
ports, and those fields feed the checksum — so it necessarily recalculates and rewrites the
checksum before forwarding. If that device also damages the payload, the checksum it writes
is computed over the *already-damaged* bytes:

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
pathrot reports the per-packet rate it infers, so you can see where your path sits on that scale.

## Why TLS dies instead of recovering

TLS detects the damage — and then has no way to fix it.

It sits *above* TCP, and TCP has already acknowledged those bytes and dropped them from its
send buffer, so there is nothing left to retransmit. TLS is also stateful: record sequence
numbers and the key schedule advance together, so a failed authentication means the integrity
of the whole stream is no longer guaranteed. The specification requires terminating the
connection.

So one damaged packet in a thousand destroys an entire multi-megabyte upload, over and over.

## Why a tunnel fixes it

Send the same traffic through WireGuard (Tailscale, or any WireGuard-based VPN) and the
corruption does not stop — but it stops mattering.

WireGuard authenticates **every packet**, and it does so **below TCP**. A damaged packet fails
its Poly1305 tag and is silently discarded. The TCP connection inside the tunnel never sees
damaged data — it sees a packet that never arrived, notices the missing ACK, and retransmits.

**A tunnel does not prevent corruption. It converts corruption into packet loss** — and packet
loss is what TCP has been designed to handle since 1981.

| | direct | through a tunnel |
| --- | --- | --- |
| where integrity is checked | above TCP (TLS) | below TCP (per packet) |
| a damaged packet causes | connection terminated | one packet dropped |
| recoverable? | no — start over | yes — retransmit |
| cost | — | the tunnel's own bandwidth and latency |

The same reasoning is why QUIC/HTTP-3 is naturally immune: it authenticates per packet and
retransmits its own losses, with no tunnel required. If your client can speak HTTP/3, try that first.

## What to do when pathrot says your path is rotten

1. **Tunnel out.** Any WireGuard-based VPN. This is the fix that works without cooperation
   from whoever owns the broken device.
2. **Change networks.** Phone hotspot, wired, a different access point.
3. **Rate-limit**, if pathrot classified the fault as burst-triggered. Usually as slow as
   tunnelling for less reliability, but it needs no infrastructure.
4. **If round 6 convicted your own machine**, disable TCP segmentation offload and re-run:
   `sudo sysctl -w net.inet.tcp.tso=0` (macOS) or `sudo ethtool -K <iface> tso off gso off` (Linux).

## Caveats

- **Probes cost bandwidth.** Default settings upload roughly 18 MB per run to a public
  speed-test endpoint. Use `-q`, or point `PATHROT_URL` at your own server, on metered links.
- **The fault is intermittent.** A clean run does not prove a clean path. If your application
  is failing right now and pathrot says clean, re-run with `-n 32`.
- **Round 6 needs a peer.** Without `--lan-peer` pathrot cannot fully rule out your own NIC.
- **Public endpoints are a courtesy.** Don't run this on a loop against Cloudflare or httpbin;
  set `PATHROT_URL` to something you own if you want continuous monitoring.

## Development

```sh
./test.sh
```

Tests use the `PATHROT_FAKE` seam (a string of `.` ok / `!` corrupt / `~` timeout characters
replayed in place of real probes), so the suite runs offline and deterministically.

## Prior art and reading

- Stone & Partridge, *When the CRC and TCP Checksum Disagree*, SIGCOMM 2000 —
  [PDF](https://conferences.sigcomm.org/sigcomm/2000/conf/paper/sigcomm2000-9-1.pdf)
- [`cshatag`](https://github.com/rfjakob/cshatag) — the same idea applied to data at rest
- Reports that look like this failure, still open and undiagnosed:
  [claude-code#13657](https://github.com/anthropics/claude-code/issues/13657),
  [#5674](https://github.com/anthropics/claude-code/issues/5674)

## License

MIT
