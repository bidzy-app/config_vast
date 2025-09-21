#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${COMFY_ROOT:-/opt/ComfyUI}
INP="$ROOT/input"; mkdir -p "$INP"
IMG_URL=${IMG_URL:-}; AUD_URL=${AUD_URL:-}
IMG_DEF=${IMG_DEF_EXT:-png}; AUD_DEF=${AUD_DEF_EXT:-m4a}
mkname(){ U="$1"; DEF="$2"; [ -z "$U" ] && echo "" && return 0; B="$(basename "${U%%\?*}")"; E="${B##*.}"; [ "$E" = "$B" ] || [ ${#E} -gt 5 ] && E="$DEF"; H="$(printf %s "$U" | sha256sum | cut -c1-16)"; echo "$H.$E"; }
IFN="$(mkname "$IMG_URL" "$IMG_DEF")"; AFN="$(mkname "$AUD_URL" "$AUD_DEF")"
echo "IMG_URL=$IMG_URL"; echo "AUD_URL=$AUD_URL"; echo "IFN=$IFN"; echo "AFN=$AFN"
[ -n "$IMG_URL" ] && [ -n "$IFN" ] && (curl -fsSL "$IMG_URL" -o "$INP/$IFN" || wget -qO "$INP/$IFN" "$IMG_URL" || true)
[ -n "$AUD_URL" ] && [ -n "$AFN" ] && (curl -fsSL "$AUD_URL" -o "$INP/$AFN" || wget -qO "$INP/$AFN" "$AUD_URL" || true)
printf '{"image":"%s","audio":"%s"}\n' "$IFN" "$AFN" > "$INP/.inputs.json" 2>/dev/null || true
ls -lah "$INP" || true