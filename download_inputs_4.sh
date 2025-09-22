#!/usr/bin/env bash
set -Eeuo pipefail

LOGF=/var/log/input_downloads.log
{
  echo "==== $(date -u) download_inputs_4.sh ===="

  ROOT="${COMFY_REAL_ROOT:-${COMFY_ROOT:-/opt/ComfyUI}}"
  STAGE="/opt/input_cache"; mkdir -p "$STAGE"

  echo "COMFY_ROOT=${COMFY_ROOT:-<unset>}"; echo "COMFY_REAL_ROOT=${COMFY_REAL_ROOT:-<unset>}"; echo "ROOT=$ROOT"

  IMG_URL="${IMG_URL:-}"; AUD_URL="${AUD_URL:-}"
  norm(){ echo "$1" | sed -E 's#https://github.com/([^/]+)/([^/]+)/blob/([^?]+).*#https://raw.githubusercontent.com/\1/\2/\3#'; }
  [ -n "$IMG_URL" ] && IMG_URL="$(norm "$IMG_URL")"
  [ -n "$AUD_URL" ] && AUD_URL="$(norm "$AUD_URL")"

  IMG_DEF="${IMG_DEF_EXT:-png}"; AUD_DEF="${AUD_DEF_EXT:-m4a}"
  mkname(){ U="$1"; DEF="$2"; [ -z "$U" ] && echo "" && return 0; B="$(basename "${U%%\?*}")"; E="${B##*.}"; [ "$E" = "$B" ] || [ ${#E} -gt 5 ] && E="$DEF"; H="$(printf %s "$U" | sha256sum | cut -c1-16)"; printf "%s.%s" "$H" "$E"; }
  IFN="$(mkname "$IMG_URL" "$IMG_DEF")"; AFN="$(mkname "$AUD_URL" "$AUD_DEF")"
  echo "IMG_URL=$IMG_URL"; echo "AUD_URL=$AUD_URL"; echo "IFN=$IFN"; echo "AFN=$AFN"

  fetch(){ SRC="$1" OUT="$2"; [ -z "$SRC" ] || [ -z "$OUT" ] && return 0
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 --create-dirs -o "$OUT" "$SRC"; then
      command -v wget >/dev/null 2>&1 && wget -q --tries=3 --timeout=60 -O "$OUT" "$SRC" || true
    fi
  }

  [ -n "$IMG_URL" ] && [ -n "$IFN" ] && fetch "$IMG_URL" "$STAGE/$IFN"
  [ -n "$AUD_URL" ] && [ -n "$AFN" ] && fetch "$AUD_URL" "$STAGE/$AFN"

  INP="$ROOT/input"

  for i in $(seq 1 60); do
    if [ -L "$ROOT" ] && [ "$(readlink "$ROOT" || true)" = "$ROOT" ]; then
      echo "Fixing self-symlink at $ROOT"
      unlink "$ROOT" || true
      mkdir -p "$ROOT"
      chmod 2775 "$ROOT" || true
    fi

    mkdir -p "$INP" 2>/dev/null || true

    copied=0
    if [ -n "$IFN" ] && [ -f "$STAGE/$IFN" ]; then
      cp -f "$STAGE/$IFN" "$INP/$IFN" 2>/dev/null && copied=1 || true
    fi
    if [ -n "$AFN" ] && [ -f "$STAGE/$AFN" ]; then
      cp -f "$STAGE/$AFN" "$INP/$AFN" 2>/dev/null && copied=1 || true
    fi

    printf '{"image":"%s","audio":"%s"}\n' "${IFN:-}" "${AFN:-}" > "$INP/.inputs.json" 2>/dev/null || true

    if [ $copied -eq 1 ] || [ -f "$INP/$IFN" ] || [ -f "$INP/$AFN" ]; then
      echo "Inputs placed into $INP"
      break
    fi
    sleep 2
  done

  echo "Target input dir listing ($INP):"
  ls -lah "$INP" 2>/dev/null || true

  echo "Stage dir listing ($STAGE):"
  ls -lah "$STAGE" 2>/dev/null || true
} >>"$LOGF" 2>&1