#!/usr/bin/env bash
# Phase 3 cloud MapReduce (Tasks 1, 3-6). Run from the repo root in Google Cloud Shell:
#     bash phase-3-mapreduce-spark/deploy.sh
# Safe to re-run: steps whose resource already exists are skipped.
set -euo pipefail

export PROJECT=$(gcloud config get-value project)
export REGION=us-central1
export SA=mr-runner@$PROJECT.iam.gserviceaccount.com
echo ">> project=$PROJECT region=$REGION"

# --- Task 1: APIs -----------------------------------------------------------
gcloud services enable storage.googleapis.com bigquery.googleapis.com \
    cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com workflows.googleapis.com logging.googleapis.com

# --- Task 3: the job's identity: run.invoker + storage.objectAdmin only -----
if ! gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
  gcloud iam service-accounts create mr-runner --display-name="MapReduce runner"
  sleep 15   # let the new account propagate before granting roles
fi
for ROLE in roles/run.invoker roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
      --role="$ROLE" --condition=None --quiet >/dev/null
  echo "granted $ROLE to $SA"
done
echo ">> roles held by mr-runner:"
gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$SA" --format="value(bindings.role)"

# --- Task 4: the worker function (private: no unauthenticated access) -------
gcloud functions deploy mr-worker --gen2 --region=$REGION --runtime=python311 \
    --source=phase-3-mapreduce-spark --entry-point=mr_worker --trigger-http \
    --no-allow-unauthenticated --service-account="$SA" --timeout=300
export WORKER_URL=$(gcloud functions describe mr-worker --gen2 --region=$REGION \
    --format='value(serviceConfig.uri)')
echo ">> unauthenticated POST must answer 403:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$WORKER_URL"

# --- Task 5: the workflow (job tracker) -------------------------------------
gcloud workflows deploy mr-wordcount --location=$REGION \
    --source=phase-3-mapreduce-spark/workflow.yaml --service-account="$SA"

# --- Task 6: run the job, then break it -------------------------------------
python3 -m venv ~/.venv-phase3
source ~/.venv-phase3/bin/activate
pip -q install -r requirements.txt -r phase-3-mapreduce-spark/requirements.txt

echo; echo "================ normal run ================"
python phase-3-mapreduce-spark/run_mr.py --project "$PROJECT" --region $REGION --worker-url "$WORKER_URL"

echo; echo "================ chaos run (--chaos 0.3) ================"
CHAOS_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python phase-3-mapreduce-spark/run_mr.py --project "$PROJECT" --region $REGION --worker-url "$WORKER_URL" --chaos 0.3

echo; echo ">> waiting 30s for request logs to arrive, then counting 503s (= retried attempts)"
sleep 30
RETRIES=$(gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"mr-worker\" AND httpRequest.status=503 AND timestamp>=\"$CHAOS_START\"" \
  --format='value(timestamp)' --limit=200 | wc -l)
echo "simulated worker crashes (HTTP 503) during the chaos run: $RETRIES"

echo; echo "================ phase3_mapreduce.json ================"
cat submission/phase3_mapreduce.json
