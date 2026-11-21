#!/usr/bin/env bash
# Keeps trying to create an Always Free A1 VM (2 OCPU / 12 GB) in Mumbai until capacity frees up.
#   Cloud Shell:     bash oci-a1-retry.sh            (retries forever)
#   GitHub Actions:  run by .github/workflows/oci-a1-retry.yml (MAX_MINUTES per run, quiet logs)
# Stays inside Always Free: one A1 2 OCPU/12 GB, 50 GB boot volume, free VCN + ephemeral public IP.

set -u
REGION="ap-mumbai-1"
NAME="surajvps"
OCPUS=2
MEM_GB=12
BOOT_GB=50
SLEEP_SECS=60
MAX_MINUTES="${MAX_MINUTES:-0}"   # 0 = no limit
QUIET="${QUIET:-0}"               # 1 = don't print IDs/IP (public CI logs)

oci() { command oci --region "$REGION" "$@"; }
say() { echo "$@"; }
info() { [ "$QUIET" = "1" ] || echo "$@"; }
mark_done() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "done=true" >> "$GITHUB_OUTPUT"; return 0; }

C="${OCI_TENANCY:-}"
if [ -z "$C" ]; then say "OCI_TENANCY not set (Cloud Shell sets it; in CI it comes from secrets)."; exit 1; fi

# --- SSH public key (safe to share; the private .key file stays with you) ---
KEYFILE="$HOME/surajvps_key.pub"
cat > "$KEYFILE" <<'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGXwWnVszPbqJigD22/YzQ9ztzUyX6fD3jt3TF2+eXcuV2a6YxsZTdvD4+fxp7c1T/OpAUhKVHagMDk3xAH+XTS+5p/AxswKCxCU3/ym3UVI4fSQVcx++iwNkHFjZHeCsGCrEKyVanQtPycsKULNmx53U8F+ypFA6kQTWBuxcFxKBvgMd9Oe58/J15se+C6Jl4BTD8iXX8C1f5n5IZAbtgH1aZckGqscrQwUUFPdl9TEMxChQwNEj6ajbSP1Oq9ftV+xsTLA0AKW1dWMdGKDCWuG79sfubRV/FP86ttRHXXZI5bdwe73VLg/L7GW31K1B1wVK+d0GCjRKnxJ/WwIsf ssh-key-2026-11-21
EOF

# --- Safety: never create a second VM (going over the free A1 limit disables all A1 VMs) ---
existing_count() {
  local n
  n=$(oci compute instance list -c "$C" --all 2>/dev/null \
      | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | length')
  echo "${n:-0}"
}
if [ "$(existing_count)" -gt 0 ]; then
  say "An instance already exists - not creating another (stays Always Free)."
  mark_done
  exit 0
fi

# --- Availability domain ---
AD=$(oci iam availability-domain list -c "$C" | jq -r '.data[0].name')
[ -z "$AD" ] || [ "$AD" = "null" ] && { say "Could not read availability domain (auth problem?)."; exit 1; }
info "AD: $AD"

# --- Ubuntu 24.04 (full, ARM) image ---
IMG=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
      --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all \
      | jq -r '[.data[] | select(."display-name" | test("Minimal") | not)][0].id')
[ -z "$IMG" ] || [ "$IMG" = "null" ] && { say "Could not find Ubuntu 24.04 ARM image."; exit 1; }
info "Image: $IMG"

# --- Network: reuse a public subnet if one exists, else create a free VCN + public subnet ---
SUBNET=$(oci network subnet list -c "$C" --all 2>/dev/null \
         | jq -r '[.data[]? | select(."prohibit-public-ip-on-vnic" == false and ."lifecycle-state" == "AVAILABLE")][0].id // empty')
if [ -z "$SUBNET" ]; then
  say "No public subnet found - creating VCN, internet gateway and public subnet..."
  VCN_JSON=$(oci network vcn create -c "$C" --cidr-blocks '["10.0.0.0/16"]' --display-name vps-vcn \
             --dns-label vpsvcn --wait-for-state AVAILABLE)
  VCN=$(echo "$VCN_JSON" | jq -r '.data.id')
  RT=$(echo "$VCN_JSON" | jq -r '.data."default-route-table-id"')
  IGW=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN" --is-enabled true \
        --display-name vps-igw --wait-for-state AVAILABLE | jq -r '.data.id')
  oci network route-table update --rt-id "$RT" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null
  SUBNET=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block 10.0.0.0/24 \
           --display-name vps-subnet --dns-label vpssubnet --wait-for-state AVAILABLE | jq -r '.data.id')
fi
[ -z "$SUBNET" ] || [ "$SUBNET" = "null" ] && { say "Could not get a subnet."; exit 1; }
info "Subnet: $SUBNET"

# --- Retry loop ---
START=$(date +%s)
attempt=0
while true; do
  if [ "$MAX_MINUTES" != "0" ] && [ $(( $(date +%s) - START )) -ge $(( MAX_MINUTES * 60 )) ]; then
    say "Time budget for this run used up - next run will keep trying."
    exit 0
  fi
  attempt=$((attempt + 1))
  if [ "$(existing_count)" -gt 0 ]; then say "Instance exists now - stopping."; mark_done; exit 0; fi

  say "[$(date -u '+%H:%M:%S') UTC] Attempt $attempt: A1 ${OCPUS} OCPU / ${MEM_GB} GB..."
  OUT=$(oci compute instance launch -c "$C" --availability-domain "$AD" \
        --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
        --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
        --boot-volume-size-in-gbs "$BOOT_GB" --display-name "$NAME" \
        --ssh-authorized-keys-file "$KEYFILE" 2>&1)

  if echo "$OUT" | grep -q '"lifecycle-state"'; then
    say "SUCCESS - instance created."
    mark_done
    if [ "$QUIET" != "1" ]; then
      ID=$(echo "$OUT" | sed -n '/^{/,$p' | jq -r '.data.id')
      oci compute instance get --instance-id "$ID" --wait-for-state RUNNING --max-wait-seconds 600 >/dev/null 2>&1
      IP=$(oci compute instance list-vnics --instance-id "$ID" | jq -r '.data[0]."public-ip"')
      say "Public IP: $IP"
      say "Connect:  ssh -i ssh-key-2026-11-21.key ubuntu@$IP"
    else
      say "Get the public IP from the Oracle console: Compute > Instances > surajvps."
    fi
    exit 0
  elif echo "$OUT" | grep -qi 'out of host capacity\|OutOfCapacity\|out of capacity'; then
    if [ -n "${MAX_ATTEMPTS:-}" ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      say "  Out of capacity. Next scheduled run will try again."
      exit 0
    fi
    say "  Out of capacity. Retrying in ${SLEEP_SECS}s..."
    sleep "$SLEEP_SECS"
  elif echo "$OUT" | grep -qi 'TooManyRequests\|"status": 429'; then
    say "  Rate limited. Waiting 3 min..."
    sleep 180
  else
    say "  Unexpected error - stopping so nothing goes wrong:"
    if [ "$QUIET" = "1" ]; then echo "$OUT" | grep -iE '"code"|"message"' | head -n 4; else echo "$OUT"; fi
    exit 1
  fi
done
