#!/usr/bin/env bash
# Generate an image with Google's "Nano Banana" (gemini-2.5-flash-image) or
# "Nano Banana Pro" (gemini-3-pro-image-preview) via Vertex AI using ADC.
#
# Auth:   gcloud auth application-default login
# Enable: gcloud services enable aiplatform.googleapis.com
#
# Usage:
#   scripts/nanobanana.sh "a red fox in watercolor"
#   scripts/nanobanana.sh -o fox.png -m pro -r 2048 "a red fox, studio lighting"
#
# Output goes to ./nanobanana-output/<timestamp>-<name>.png by default.

set -euo pipefail

# Resolve gcloud binary (PATH may not include it in all shells)
GCLOUD="${GCLOUD:-}"
if [[ -z "$GCLOUD" ]]; then
    if command -v gcloud >/dev/null 2>&1; then
        GCLOUD="$(command -v gcloud)"
    elif [[ -x "$HOME/google-cloud-sdk/bin/gcloud" ]]; then
        GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
    else
        echo "Error: gcloud not found. Install it or set GCLOUD=/path/to/gcloud." >&2
        exit 2
    fi
fi

PROJECT="${GOOGLE_CLOUD_PROJECT:-$("$GCLOUD" config get-value project 2>/dev/null || true)}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
MODEL="gemini-2.5-flash-image"
OUTFILE=""
ASPECT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] "<prompt>"

Options:
  -o, --out FILE        Output file (default: nanobanana-output/<ts>-image.png)
  -m, --model MODEL     flash (default) | pro
  -a, --aspect RATIO    e.g. 16:9, 1:1, 4:3
  -p, --project ID      Override GCP project (default: active gcloud project)
  -l, --location LOC    Override region (default: us-central1)
  -h, --help            Show this help

Env:
  GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)      OUTFILE="$2"; shift 2 ;;
        -m|--model)
            case "$2" in
                flash) MODEL="gemini-2.5-flash-image" ;;
                pro)   MODEL="gemini-3-pro-image-preview" ;;
                *)     MODEL="$2" ;;
            esac
            shift 2 ;;
        -a|--aspect)   ASPECT="$2"; shift 2 ;;
        -p|--project)  PROJECT="$2"; shift 2 ;;
        -l|--location) LOCATION="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)  break ;;
    esac
done

PROMPT="${1:-}"
if [[ -z "$PROMPT" ]]; then
    echo "Error: prompt is required" >&2
    usage >&2
    exit 2
fi

if [[ -z "$PROJECT" ]]; then
    echo "Error: no GCP project set. Run 'gcloud config set project <id>' or pass --project." >&2
    exit 2
fi

for cmd in jq base64 curl; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' not found in PATH" >&2; exit 2; }
done

if [[ -z "$OUTFILE" ]]; then
    mkdir -p nanobanana-output
    OUTFILE="nanobanana-output/$(date +%Y%m%d-%H%M%S)-image.png"
fi

TOKEN="$("$GCLOUD" auth application-default print-access-token)"

BODY="$(jq -n \
    --arg prompt "$PROMPT" \
    --arg aspect "$ASPECT" \
    '{
        contents: [{ role: "user", parts: [{ text: $prompt }] }],
        generationConfig: (
            { responseModalities: ["IMAGE", "TEXT"] } +
            (if $aspect != "" then { imageConfig: { aspectRatio: $aspect } } else {} end)
        )
    }')"

URL="https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/${LOCATION}/publishers/google/models/${MODEL}:generateContent"

echo "→ project=$PROJECT location=$LOCATION model=$MODEL"
RESPONSE="$(curl -sS -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$URL" \
    -d "$BODY")"

if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo "API error:" >&2
    echo "$RESPONSE" | jq '.error' >&2
    exit 1
fi

B64="$(echo "$RESPONSE" | jq -r '
    .candidates[0].content.parts[]
    | select(.inlineData != null)
    | .inlineData.data
')"

if [[ -z "$B64" ]]; then
    echo "No image in response:" >&2
    echo "$RESPONSE" | jq '.' >&2
    exit 1
fi

echo "$B64" | base64 -d > "$OUTFILE"
echo "✅ Saved: $OUTFILE"

if [[ "$(uname)" == "Darwin" ]]; then
    open "$OUTFILE" 2>/dev/null || true
fi
