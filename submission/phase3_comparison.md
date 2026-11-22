# Phase 3 — Comparison Writeup

Copy this file to `submission/phase3_comparison.md`, fill in every answer slot, and commit it:

```bash
cp phase-3-mapreduce-spark/comparison_template.md submission/phase3_comparison.md
```

**How to fill it in.** Each answer sits between a pair of `<!--answer:...-->` markers. Replace
the `TODO` line with your answer — **leave the markers themselves untouched**, they are how the
grader finds your answers. Anything you write outside the markers is ignored, so add extra
prose, tables or images freely.

Numbers in section 1 must **match `submission/phase3_report.json`** — copy them across, do not
retype from memory; they are checked against it.

---

## 1. Facts from your runs

Numbers only (e.g. `12`, `20.3`, `0.041`).

| | Value |
|---|---|
| Map tasks in the cloud job (`mapreduce.num_splits`) | <!--answer:num_map_tasks-->12<!--/answer--> |
| Reduce tasks in the cloud job (`mapreduce.num_reducers`) | <!--answer:num_reduce_tasks-->4<!--/answer--> |
| Cloud MapReduce wall time, seconds (`mapreduce.cloud_elapsed_s`) | <!--answer:cloud_elapsed_s-->91.6<!--/answer--> |
| Local single-process wall time, seconds (`mapreduce.local_elapsed_s`) | <!--answer:local_elapsed_s-->0.028<!--/answer--> |
| Spark wall time for the `collect`, seconds (`tfidf.spark_elapsed_s`) | <!--answer:spark_elapsed_s-->7.0<!--/answer--> |
| Number of **stages** in the Spark job (read off notebook 2b / 3a) | <!--answer:num_stages-->4<!--/answer--> |
| Task **retries** you counted in your `--chaos` run (0 if none happened) | <!--answer:chaos_retries-->3<!--/answer--> |

**Explain the timings.** The three wall times above cover the same 60 documents, but not the
same job: the single-process run and the cloud MapReduce are *the same word count*; Spark's
time is for *TF-IDF*, which is more work (two `reduceByKey`s and a `join`). Rank the three and
explain what each is spending its time on. Say which comparison is like-for-like, and what the
Spark number — a heavier job, on one machine — tells you about where the cloud job's time goes.
(~80 words)

<!--answer:timing_explanation-->
Fastest to slowest: local single process 0.028 s, then Spark TF-IDF 7.0 s, then cloud MapReduce 91.6 s. The like-for-like pair is local vs cloud: the same word count over the same 60 documents. Locally that is pure CPU work on ~38k tokens, and it takes milliseconds. The cloud job is about 3,000x slower because almost all of its time is overhead, not computation: starting and scheduling 16 function invocations (including cold starts), OIDC-authenticated HTTP calls, ~65 Cloud Storage reads and writes for the inputs, shuffle and outputs, workflow step bookkeeping, and the retry backoff in the chaos run. Spark does *more* work (TF-IDF: two `reduceByKey`s and a `join`) on one machine, yet finishes in 7.0 s. Its shuffles stay in local memory and disk, and it pays JVM scheduling instead of network round trips. So the cloud job's time goes into coordination and data movement, not into counting words. On a corpus this small, that overhead is never amortised.
<!--/answer-->

**What the counts tell you.** From your stage count: how many shuffles did the Spark job have,
and which operations in `spark_tfidf.py` caused them? From your retry count: roughly what
fraction of the 16 task attempts was retried, and is that what `--chaos 0.3` should produce?
(~50 words)

<!--answer:counts_interpretation-->
4 stages means 3 shuffle boundaries, one for each wide operation in `spark_tfidf.py`: the `reduceByKey` in `term_freq` (stage 0 → 1), the `reduceByKey` in `doc_freq` (stage 1 → 2) and the `join` of TF with DF (stage 2 → 3). Retries: 3 of the 16 task attempts, about 19%, failed with a simulated 503 and were retried. `--chaos 0.3` gives each attempt a 30% chance of failing, so about 4.8 failed first attempts (and ~6.9 retries including repeat failures) would be the average. 3 is on the low side, but well within the random variation of 16 coin flips.
<!--/answer-->

---

## 2. Spark: transformations, actions, lineage

**Transformations vs actions.** Go through `spark_tfidf.py` and the notebook's Spark cells.
Name each RDD operation and say whether it is a transformation or an action. What happened
when you ran `build_tfidf_rdd` — and what happened when you ran `collect`? (~60 words)

<!--answer:transformations_vs_actions-->
Transformations (lazy, they only extend the lineage): `parallelize` (creates the source RDD), `flatMap` and `reduceByKey` in `term_freq`, `map` and `reduceByKey` in `doc_freq`, then `map` (re-key TF by term), `join` and `map` (`to_row`) in `build_tfidf_rdd`. Actions (trigger execution): `collect` in 2c, and `toDebugString`, which only prints the plan. Running `build_tfidf_rdd` returned instantly and computed nothing: it only recorded the graph we printed in 2b. Running `collect` made Spark cut that graph into 4 stages and 12 tasks, run them, and ship 5975 rows to the driver in 7.0 s.
<!--/answer-->

**Lineage and recovery.** Using the lineage you printed in 2b and the timeline in 3a: if the
worker holding one output partition of the *first* `reduceByKey` died, what would Spark have
to recompute, and what could it reuse? Name the stage or shuffle boundary where the recovery
starts. (~50 words)

<!--answer:lineage_recovery-->
If the executor holding one output partition of the first `reduceByKey` (`term_freq`, ShuffledRDD[3], end of stage 0) died, Spark would recompute only that partition. It re-runs the stage-0 map tasks that fed it, from the `ParallelCollectionRDD` source, and rebuilds ShuffledRDD[3]'s lost partition. The other partitions, and any downstream shuffle files that are still present, are reused. Recovery starts at the first shuffle boundary (stage 0 → 1). This is the same mechanism that marks stages SKIPPED when 2c is re-run.
<!--/answer-->

---

## 3. Your cloud MapReduce, mapped onto Hadoop

Name the GCP service or file that played each role (one line each):

- **JobTracker** (schedules tasks, waits for the map phase, retries failures):
  <!--answer:role_jobtracker-->Cloud Workflows: the `mr-wordcount` workflow (`workflow.yaml`), which fans out map tasks, waits at the barrier and retries failures.<!--/answer-->
- **Workers** (run your map and reduce code):
  <!--answer:role_workers-->The `mr-worker` Cloud Run function (2nd-gen Cloud Function, `main.py`), one invocation per map or reduce task, running as `mr-runner`.<!--/answer-->
- **HDFS** (holds inputs, shuffle files, outputs):
  <!--answer:role_hdfs-->Cloud Storage: the `project-50f5d660-b126-43b5-90d-eurecomgpt` bucket, holding `<job>/input/`, `<job>/shuffle/` and `<job>/output/`.<!--/answer-->
- **Partitioner** (decides which reducer owns a key):
  <!--answer:role_partitioner-->`partition()` in `mapreduce.py`: `zlib.crc32(word) % num_reducers`, called by `run_map` in `main.py`.<!--/answer-->

**The barrier.** There is no explicit "wait for all mappers" step in `workflow.yaml`. Where,
exactly, is the barrier between the map and reduce phases — which construct provides it?
(~30 words)

<!--answer:barrier_location-->
The `map_phase` step itself. A `parallel` step only completes when all of its `for` branches have finished (including their retries), so the next step, `reduce_phase`, cannot start before the last map task is done.
<!--/answer-->

**Idempotence.** The workflow retries a task that failed. Why is that safe with the worker as
written, and what would go wrong if `run_map` *appended* its pairs to the shuffle file instead
of overwriting it? (~60 words)

<!--answer:idempotence-->
Each map task writes its shuffle files to fixed, deterministic keys (`<job>/shuffle/split-NNN/part-r.json`) and overwrites them, and the chaos failure happens before any read or write. So re-running a task, even one that crashed halfway, produces exactly the same objects, and a retry can never double-count. If `run_map` appended instead, a task that wrote some pairs and then failed (or timed out after writing) would append them again on retry. The reducers would then count those words twice, and the cloud result would no longer match the local reference.
<!--/answer-->

**The chaos run.** What did you see in the execution log and in Logs Explorer when you ran
with `--chaos 0.3`? Did the job still succeed, and was the final answer still identical to the
local reference? (~50 words)

<!--answer:chaos_observations-->
With `--chaos 0.3`, the execution's Steps view showed some `call_map`/`call_reduce` steps with failed attempts followed by retries after a backoff. In Logs Explorer, filtering on the `mr-worker` service showed 3 requests that returned HTTP 503 (`simulated worker crash`) during the run. The job still finished SUCCEEDED (91.6 s, about the same as the 98.7 s normal run) with 2221 distinct words, and `identical: True`: exactly the same counts as the local reference.
<!--/answer-->
