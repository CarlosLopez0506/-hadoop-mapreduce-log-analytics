# Sample Output — NASA HTTP Access Log MapReduce Demo

Dataset: NASA Kennedy Space Center HTTP access log, July 1995  
Input: `NASA_access_log_Jul95` — 205,242,368 bytes, 1,891,715 lines

---

## Job 1: Top 20 Requested Resources

Command: `make job-top`  
Wall-clock: ~27 s

```
/images/NASA-logosmall.gif                              111330
/images/KSC-logosmall.gif                               89638
/images/MOSAIC-logosmall.gif                            60467
/images/USA-logosmall.gif                               60013
/images/WORLD-logosmall.gif                             59488
/images/ksclogo-medium.gif                              58801
/images/launch-logo.gif                                 40871
/shuttle/countdown/                                     40276
/ksc.html                                               40223
/images/ksclogosmall.gif                                33585
/                                                       32830
/history/apollo/images/apollo-logo1.gif                 31072
/shuttle/missions/missions.html                         24864
/htbin/cdt_main.pl                                      22626
/shuttle/countdown/count.gif                            22216
/shuttle/countdown/liftoff.html                         21996
/shuttle/countdown/count70.gif                          20956
/images/launchmedium.gif                                20812
/shuttle/missions/sts-71/sts-71-patch-small.gif         19852
/shuttle/missions/sts-70/sts-70-patch-small.gif         18159
```

### Key counters

| Counter | Value |
|---|---|
| Map input records | 1,891,715 |
| Combine input records | 1,889,757 |
| Reduce output records | 21,104 |
| nasa.malformed_line | 2 |
| nasa.unparsed_request | 1,956 |

Combiner reduced 1,889,757 intermediate records to 26,793 before the shuffle — a ~70× reduction in bytes over the network.

---

## Job 2: HTTP Status Distribution

Command: `make job-status`  
Wall-clock: ~34 s

```
Status   Requests       Bytes
200      1,701,534      38,692,291,442
302         46,573           3,682,049
304        132,627                   0
400              5                   0
403             54                   0
404         10,844                   0
500             62                   0
501             14                   0
```

Total requests: 1,891,713 (= input − 2 malformed lines)

### Key counters

| Counter | Value |
|---|---|
| Map input records | 1,891,715 |
| Combine input records | 0 |
| Reduce output records | 8 |
| nasa.malformed_line | 2 |

No combiner: the mapper emits composite values (`status\t1\tbytes`) that are not commutative+associative as a unit.

---

## Observations

- Status 304 (Not Modified) accounts for 132,627 requests with exactly 0 bytes transferred, matching HTTP/1.1 spec.
- The top resource (`/images/NASA-logosmall.gif`, 111,330 hits) is a 766-byte GIF served on nearly every page load.
- The STS-71 mission patch appears in the top 20 — STS-71 was the first Shuttle–Mir docking mission, launched 27 June 1995, two days before this log begins.
