# Phase 1 — Comparison Report

Copy this file to `submission/phase1_report.md`, fill in every answer slot, and commit it:

```bash
cp phase-1-echo-bot/report_template.md submission/phase1_report.md
```

**How to fill it in.** Each answer sits between a pair of `<!--answer:...-->` markers. Replace
the `TODO` line with your answer — **leave the markers themselves untouched**, they are how the
grader finds your answers. Anything you write outside the markers is ignored, so add extra
prose, tables or images freely.

Numbers must **match `submission/phase1_report.json`** exactly — that file is produced by
`measure.py` and is what your figures are checked against. Copy them across; do not retype from
memory.

---

## 1. Setup facts

**Your image size**, in MB, from `gcloud artifacts docker images list` (number only, e.g. `142`):

<!--answer:image_size_mb-->
50
<!--/answer-->

**The custom VPC and subnet you created** (names only):

<!--answer:vpc_name-->
echo-net
<!--/answer-->

<!--answer:subnet_name-->
echo-subnet
<!--/answer-->

---

## 2. Measurements

Copy these from `submission/phase1_report.json`. Cold is `cold_ms`; warm median is
`stats.median`. Numbers only, in milliseconds (e.g. `812.4`).

| Platform | Cold (ms) | Warm median (ms) |
|---|---|---|
| IaaS VM | <!--answer:vm_cold_ms-->239.1<!--/answer--> | <!--answer:vm_warm_median_ms-->211.6<!--/answer--> |
| Cloud Run | <!--answer:cloudrun_cold_ms-->2150.1<!--/answer--> | <!--answer:cloudrun_warm_median_ms-->635.3<!--/answer--> |
| Cloud Function | <!--answer:function_cold_ms-->1121.3<!--/answer--> | <!--answer:function_warm_median_ms-->636.0<!--/answer--> |

Include your histogram or plot of the warm distribution below (an image, or the ASCII chart
`measure.py` prints). This is read by a human, not the grader:

<!--answer:latency_plot-->
```
Warm-latency histogram (20 requests each, from Cloud Shell, ms):

IaaS VM  (cold 239.1 ms, warm median 211.6 ms)
  100-200 |
  200-300 | #################### 20
  300-400 |
  400-500 |
  500-600 |
  600-700 |

Cloud Run  (cold 2150.1 ms, warm median 635.3 ms)
  100-200 | #### 4
  200-300 |
  300-400 |
  400-500 |
  500-600 |
  600-700 | ################ 16

Cloud Function  (cold 1121.3 ms, warm median 636.0 ms)
  100-200 | ### 3
  200-300 |
  300-400 |
  400-500 |
  500-600 |
  600-700 | ################# 17

Cold vs warm median (one # = 50 ms):
  IaaS VM         cold #####
                  warm ####
  Cloud Run       cold ###########################################
                  warm #############
  Cloud Function  cold ######################
                  warm #############
```

The VM is tightly clustered around 211 ms: that is essentially two network round trips from Cloud Shell to us-central1 over plain HTTP (TCP handshake + request), and its "cold" request (239.1 ms) is barely slower because the container never stops, so the VM has no meaningful cold start. Cloud Run and the Function are bimodal: most warm requests take ~635 ms (measure.py opens a new connection for every request, so the TCP + TLS handshakes to the Google front end are paid every time on top of the request itself), with a few at ~120-130 ms. The cold requests (2150.1 ms and 1121.3 ms) add instance start-up on top of that: scheduling a container, pulling the image and starting the Python process.
<!--/answer-->

---

## 3. Per-platform analysis

**Scaling behaviour.** Imagine requests arriving one at a time, then ten at once, then a
hundred. For each of the three platforms, answer concretely:

- Does anything get created automatically to absorb the load — and if so, *what* exactly?
  (One platform here creates nothing at all.)
- What is the hard limit, and where does it come from — a flag you passed yourself, or the
  size of the machine you picked?

(~80 words. Your `--machine-type=e2-micro` and `--max-instances=3` are both concrete answers
to the second question.)

<!--answer:scaling_behaviour-->
**IaaS VM:** nothing is created automatically. One e2-micro (2 shared vCPUs, 1 GB RAM) runs one container with gunicorn (1 worker, 8 threads). Ten or a hundred concurrent requests just queue on that box, so the hard limit is the machine size I picked (`--machine-type=e2-micro`). Scaling means resizing it by hand or building a managed instance group myself.
**Cloud Run:** new container instances of my image are started automatically as concurrency rises (up to 80 requests per instance by default), and it scales back to zero when idle. The hard limit is the flag I passed: `--max-instances=3`.
**Cloud Function (gen 2):** the same mechanism. It is backed by a Cloud Run service, so new instances of the buildpack-built function container are created on demand and removed when idle. It is bounded by the function's max-instances setting (the platform default, since I didn't cap it) and by regional quota.
<!--/answer-->

**Deployment effort.** What did you have to build, configure and maintain to get each of the
three running? (~100 words)

<!--answer:deployment_effort-->
**IaaS VM:** the most work. I had to build and push the image, create a custom VPC, a subnet and two tagged firewall rules (8080 and 22, since a custom VPC denies all ingress), grant the VM's service account `artifactregistry.reader`, create the e2-micro with the right subnet, tag and scopes, then install Docker, authenticate to Artifact Registry and run the container (done in a startup script). I also own OS patching, restarts and the billed external IP.
**Cloud Run:** just the image plus one `gcloud run deploy` command (port, public access, min 0 / max 3). HTTPS, a URL, scaling and restarts are managed for me.
**Cloud Function:** the least work. No Dockerfile is involved: `gcloud functions deploy` with the source folder, runtime and entry point, and Google builds the container with buildpacks. The only friction was granting Cloud Build permissions to the compute service account.
<!--/answer-->

---

## 4. Why do two of your three numbers look alike?

With Cloud Run and your Function both deployed, run `gcloud run services list` and paste the
**complete output** here, unedited:

<!--answer:run_services_list-->
```
✔
SERVICE: echo
REGION: us-central1
URL: https://echo-695205065138.us-central1.run.app
LAST DEPLOYED BY: service-695205065138@gcf-admin-robot.iam.gserviceaccount.com
LAST DEPLOYED AT: 2026-10-25T21:18:51.130556Z

✔
SERVICE: echo-bot
REGION: us-central1
URL: https://echo-bot-695205065138.us-central1.run.app
LAST DEPLOYED BY: mohamed-ghassen.bousalem@eurecom.fr
LAST DEPLOYED AT: 2026-10-25T21:18:01.965947Z
```
<!--/answer-->

Now explain what that output tells you about how your Function is actually being run, why its
cold start resembles Cloud Run's so closely, and what — if anything — genuinely differs between
the two deployment paths. (~120 words)

<!--answer:convergence_explanation-->
The list contains two Cloud Run services, not one: besides `echo-bot` (which I deployed), there is `echo`, my Cloud Function, deployed by `gcf-admin-robot`, the Cloud Functions service agent. A gen-2 Cloud Function is a Cloud Run service under the hood. Cloud Functions takes my source, builds a container image with Cloud Build and buildpacks (Python 3.11 + functions-framework + main.py), stores it in Artifact Registry and deploys it to Cloud Run. Both paths therefore run on the same infrastructure, with the same scale-to-zero behaviour and the same cold-start sequence (schedule an instance, pull an image, start a Python process serving Flask), which is why their numbers sit close together and far from the always-on VM. What genuinely differs is the packaging and the control: with Cloud Run I write the Dockerfile and choose the base image, server (gunicorn 1×8) and image size; with Functions Google builds the image, so I have no control over its base image or size, and adds an event/trigger model and its own defaults on top.
<!--/answer-->
