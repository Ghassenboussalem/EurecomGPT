#!/usr/bin/env bash
# Phase 1 deploy (Tasks 1, 3-7). Run from the repo root in Google Cloud Shell:
#     bash phase-1-echo-bot/deploy.sh
# Safe to re-run: steps whose resource already exists are skipped.
set -euo pipefail

export PROJECT=$(gcloud config get-value project)
export REGION=us-central1
export ZONE=us-central1-a
export IMAGE=$REGION-docker.pkg.dev/$PROJECT/eurecomgpt/echo-bot:v1
echo ">> project=$PROJECT region=$REGION zone=$ZONE"

# --- Task 1: APIs -----------------------------------------------------------
gcloud services enable artifactregistry.googleapis.com run.googleapis.com \
    cloudfunctions.googleapis.com cloudbuild.googleapis.com compute.googleapis.com

# --- Task 3: Artifact Registry repo + image ---------------------------------
gcloud artifacts repositories describe eurecomgpt --location=$REGION >/dev/null 2>&1 ||
  gcloud artifacts repositories create eurecomgpt --repository-format=docker \
      --location=$REGION --description="EurecomGPT images"
gcloud builds submit phase-1-echo-bot --tag "$IMAGE"
gcloud artifacts docker images list $REGION-docker.pkg.dev/$PROJECT/eurecomgpt --include-tags

# --- Task 4: custom VPC, subnet, firewall -----------------------------------
gcloud compute networks describe echo-net >/dev/null 2>&1 ||
  gcloud compute networks create echo-net --subnet-mode=custom
gcloud compute networks subnets describe echo-subnet --region=$REGION >/dev/null 2>&1 ||
  gcloud compute networks subnets create echo-subnet --network=echo-net \
      --region=$REGION --range=10.10.0.0/24
gcloud compute firewall-rules describe allow-echo-8080 >/dev/null 2>&1 ||
  gcloud compute firewall-rules create allow-echo-8080 --network=echo-net \
      --direction=INGRESS --allow=tcp:8080 --target-tags=echo-http --source-ranges=0.0.0.0/0
gcloud compute firewall-rules describe allow-echo-ssh >/dev/null 2>&1 ||
  gcloud compute firewall-rules create allow-echo-ssh --network=echo-net \
      --direction=INGRESS --allow=tcp:22 --target-tags=echo-http --source-ranges=0.0.0.0/0

# --- Task 5: IaaS VM running the container ----------------------------------
# The VM's default service account needs to pull from Artifact Registry.
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
VM_SA=$PROJECT_NUMBER-compute@developer.gserviceaccount.com
gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$VM_SA" --role=roles/artifactregistry.reader \
    --condition=None --quiet >/dev/null

# Startup script: install Docker, authenticate to Artifact Registry, run the container.
cat > /tmp/echo-startup.sh <<EOF
#!/bin/bash
set -e
command -v docker >/dev/null || { apt-get update && apt-get install -y docker.io; }
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://$REGION-docker.pkg.dev
docker rm -f echo-bot 2>/dev/null || true
docker run -d --name echo-bot --restart=always -p 8080:8080 $IMAGE
EOF

gcloud compute instances describe echo-vm --zone=$ZONE >/dev/null 2>&1 ||
  gcloud compute instances create echo-vm --zone=$ZONE --machine-type=e2-micro \
      --subnet=echo-subnet --tags=echo-http \
      --image-family=debian-12 --image-project=debian-cloud \
      --service-account=$VM_SA --scopes=cloud-platform \
      --metadata-from-file=startup-script=/tmp/echo-startup.sh
VM_IP=$(gcloud compute instances describe echo-vm --zone=$ZONE \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

# --- Task 6: Cloud Run ------------------------------------------------------
gcloud run deploy echo-bot --image="$IMAGE" --region=$REGION --port=8080 \
    --allow-unauthenticated --min-instances=0 --max-instances=3
RUN_URL=$(gcloud run services describe echo-bot --region=$REGION --format='value(status.url)')

# --- Task 7: Cloud Function (gen 2) -----------------------------------------
gcloud functions deploy echo --gen2 --region=$REGION --runtime=python311 \
    --source=phase-1-echo-bot --entry-point=echo --trigger-http \
    --allow-unauthenticated --min-instances=0
FN_URL=$(gcloud functions describe echo --gen2 --region=$REGION --format='value(serviceConfig.uri)')

# --- Smoke test all three (GET + JSON POST) ---------------------------------
echo ">> waiting for the VM container to come up (Docker install takes ~1-2 min)"
for i in $(seq 1 30); do
  curl -sf "http://$VM_IP:8080/health" >/dev/null && break
  sleep 10
done
for url in "http://$VM_IP:8080" "$RUN_URL" "$FN_URL"; do
  echo "--- $url"
  curl -s "$url/echo?msg=hello"; echo
  curl -s -X POST "$url/echo" -H 'Content-Type: application/json' -d '{"message":"hello"}'; echo
done

cat <<EOF

========================================================================
All three deployed. Do NOT touch these URLs for ~15 minutes, then run:

python3 phase-1-echo-bot/measure.py \\
    --vm       http://$VM_IP:8080 \\
    --cloudrun $RUN_URL \\
    --function $FN_URL
========================================================================
EOF
gcloud run services list
