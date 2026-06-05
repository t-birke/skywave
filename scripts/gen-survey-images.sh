#!/usr/bin/env bash
# Generate the 21 Skywave survey thumbnails via Nano Banana (Vertex AI).
# Each prompt shares a unified visual instruction so the whole set reads
# coherent (modern editorial photography aesthetic, soft natural light,
# dimensional depth). Output is square 1:1 (matches the existing
# .survey-option-img { aspect-ratio: 1 } CSS).
#
# Outputs:  heroku/skywave-app/public/assets/survey/<question>-<option>.png
# Usage:    ./scripts/gen-survey-images.sh [pattern]
#   With no args, generates everything missing.
#   With a pattern (e.g. "trip_type-*" or "fav_destination-africa"), only
#   generates matching keys. Re-running is idempotent — already-existing
#   files are skipped unless FORCE=1 is set.

set -euo pipefail

OUT_DIR="heroku/skywave-app/public/assets/survey"
SCRIPT="scripts/nanobanana.sh"
mkdir -p "$OUT_DIR"

# Universal style suffix — applied to every prompt. Tuned for small square
# tiles: rich subject, no text overlay, no collage, coherent mid-range
# focus, palette consistent across the set so they look like a series.
STYLE='Square photographic composition, modern editorial travel photography style, single clear subject filling the frame, natural lighting with rich saturated color, shallow depth of field, no text or logos, no humans facing the camera, premium feel matching a high-end airline marketing campaign.'

# question_key/option_key -> prompt
read -r -d '' PROMPTS <<'EOF' || true
trip_type/beach|A pristine tropical beach with white sand and turquoise water, palm fronds at the edge of frame, gentle waves, golden afternoon light, no people.
trip_type/city|A glittering metropolitan skyline at blue hour with skyscrapers and warm window lights reflecting on a river, dense vibrant city.
trip_type/mountain|A dramatic alpine peak above the cloud line at sunrise, snow on the upper ridge, deep blue sky, no people, sense of altitude and stillness.
trip_type/cultural|A narrow European cobblestone street at golden hour, weathered stone facades, lantern glow, autumn vines, no people, evocative and historic.
trip_type/food|A close overhead shot of an artisan dinner table set with diverse beautiful dishes, warm restaurant lighting, hands of a chef plating in soft focus, abundance and craft.
trip_type/megacity|A futuristic neon megacity at night, towering glass buildings, light trails from elevated traffic, holographic billboards, vibrant teal and magenta tones.
fav_destination/europe|A sunlit Mediterranean coastal town with terracotta roofs, ancient stone arches and a glimpse of blue sea, classic old-world Europe.
fav_destination/asia|A serene Asian temple at dawn with lanterns, mist rising over a koi pond, traditional architecture, soft cherry blossom or red maple in frame.
fav_destination/americas|A vast wild American canyon at sunset, layered red rock striations, dramatic shadows, expansive horizon, sense of scale.
fav_destination/oceania|A lush South Pacific lagoon with overwater bungalows, vivid turquoise water and a coral reef visible below, swaying palms.
fav_destination/africa|A golden African savanna at dusk with a lone acacia tree silhouetted against a dust-orange sky, herd of elephants in the middle distance.
fav_destination/mideast|A desert oasis at dusk with rolling dunes, a distant Arabian palace silhouette, warm caravan lanterns, rich amber and indigo tones.
fly_frequency/1y|An open suitcase on a wooden floor packed with carefully folded summer travel essentials, soft window light, calm anticipation of one big trip.
fly_frequency/few|A minimal flat-lay of a passport, boarding pass, sunglasses and a travel journal on a linen surface, signaling regular but considered trips.
fly_frequency/monthly|A frequent traveler's compact carry-on rollerboard at a glossy airport floor, navy and teal accents, motion blur of fellow passengers in the background.
fly_frequency/weekly|A close shot of a stack of well-worn boarding passes and an embossed elite-status loyalty card, business-class lounge ambiance, signs of a heavy traveller.
cabin_class/first|A luxurious first-class private suite at altitude, plush leather seat fully reclined, ambient teal mood lighting, champagne flute on a polished side table, premium feel.
cabin_class/business|A spacious business-class window seat with a tablet on the tray, warm reading light, blanket folded neatly, sense of comfort and productivity.
cabin_class/economy|A neat modern economy cabin row with a window view of cloud tops at golden hour, friendly and approachable, clean and organized.
seat_pref/window|A close shot of a clean airplane window with cloud tops and a wing tip visible at sunset, condensation droplets on the pane, contemplative travel mood.
seat_pref/aisle|A quiet airline aisle from passenger eye level looking forward, soft cabin lighting on the seat-back monitors, sense of easy access and movement.
EOF

GENERATED=0
SKIPPED=0
FAILED=0

while IFS='|' read -r KEY PROMPT; do
    [[ -z "${KEY:-}" ]] && continue
    QUESTION="${KEY%%/*}"
    OPTION="${KEY##*/}"
    # We generate a 1024 PNG, downsize to 512 JPEG, and the JPEG is what we ship.
    OUT="${OUT_DIR}/${QUESTION}-${OPTION}.png"
    JPG="${OUT_DIR}/${QUESTION}-${OPTION}.jpg"

    # Optional pattern filter
    if [[ $# -gt 0 && "$1" != "" ]]; then
        if [[ "$KEY" != $1 && "${QUESTION}-${OPTION}" != $1 ]]; then
            continue
        fi
    fi

    if [[ -f "$JPG" && "${FORCE:-0}" != "1" ]]; then
        echo "↩  $JPG already exists (set FORCE=1 to regenerate)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    FULL_PROMPT="$PROMPT $STYLE"
    echo "→  generating  ${QUESTION}/${OPTION}"
    # Generate at 1024×1024 square then downsize to 512×512 JPEG for the web.
    # 1024 PNGs are ~1.5-2MB; the JPEG comes out ~80-150KB and looks identical
    # at the rendered size (~160px sq in CSS).
    TMP_PNG="${OUT%.png}.full.png"
    JPG_OUT="${OUT%.png}.jpg"
    if "$SCRIPT" -o "$TMP_PNG" -a 1:1 "$FULL_PROMPT" >/dev/null 2>&1; then
        # Resize and re-encode as JPEG, then drop the giant PNG.
        sips -s format jpeg -s formatOptions 85 -Z 512 "$TMP_PNG" --out "$JPG_OUT" >/dev/null 2>&1
        rm -f "$TMP_PNG"
        # Also remove any stale .png with the same name (clean slate).
        rm -f "$OUT"
        echo "✅  saved      $JPG_OUT  ($(wc -c <"$JPG_OUT" | awk '{printf "%.0fkb", $1/1024}'))"
        GENERATED=$((GENERATED+1))
    else
        echo "❌  FAILED     ${QUESTION}/${OPTION}" >&2
        FAILED=$((FAILED+1))
    fi
done <<< "$PROMPTS"

echo
echo "── summary ───────────────────────────"
echo "  generated: $GENERATED"
echo "  skipped:   $SKIPPED"
echo "  failed:    $FAILED"
[[ $FAILED -eq 0 ]]
