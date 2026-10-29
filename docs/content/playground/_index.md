---
title: Playground
summary: Run nex programs in the browser, compiled natively on a server.
weight: 20
---

{{< note >}}
The playground is not live yet.
{{< /note >}}

The playground is a page with an editor and a **Run** button. Run sends your program to a small
service that compiles it with the same compiler as `nex build` and runs the resulting native binary
on the server, then shows its output. A trap message is shown the same way as ordinary output, so the
playground prints what `nex run` prints on your machine.

Every run is sandboxed: a fresh `nsjail` per run, no network, a read-only file system apart from a
private temporary one, and limits of 2 s CPU time, 5 s wall time, 256 MB of memory and 64 KB of output,
with a cap on processes and a per-client rate limit. A program that loops forever, allocates
without bound or prints too much is stopped.

{{< note >}}
These limits are the planned ones and may change before the service opens.
{{< /note >}}
