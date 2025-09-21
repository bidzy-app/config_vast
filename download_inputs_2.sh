#!/usr/bin/env bash
set -Eeuo pipefail

LOGF=/var/log/input_downloads.log
{
  echo "==== $(date -u) download_inputs_1.sh ===="

  ROOT="${COMFY_ROOT:-/opt/ComfyUI}"

  # Диагностика путей
  echo "COMFY_ROOT=${COMFY_ROOT:-<unset>}"
  echo "ROOT=$ROOT"
  ls -ld "$ROOT" 2>/dev/null || true
  readlink -v "$ROOT" 2>/dev/null || true

  INP="$ROOT/input"

  # Не пытаемся создавать, если уже есть; иначе — не валимся при ошибке
  if [ ! -d "$INP" ]; then
    mkdir -p "$INP" 2>>"$LOGF" || echo "WARN: mkdir -p $INP failed, continue"
  fi
  ls -ld "$INP" 2>/dev/null || true

  IMG_URL="${IMG_URL:-}"
  AUD_URL="${AUD_URL:-}"
  IMG_DEF="${IMG_DEF_EXT:-png}"
  AUD_DEF="${AUD_DEF_EXT:-m4a}"

  mkname() {
    U="$1"; DEF="$2"
    [ -z "$U" ] && echo "" && return 0
    B="$(basename "${U%%\?*}")"
    E="${B##*.}"
    [ "$E" = "$B" ] || [ ${#E} -gt 5 ] && E="$DEF"
    H="$(printf %s "$U" | sha256sum | cut -c1-16)"
    printf "%s.%s" "$H" "$E"
  }

  IFN="$(mkname "$IMG_URL" "$IMG_DEF")"
  AFN="$(mkname "$AUD_URL" "$AUD_DEF")"

  echo "IMG_URL=$IMG_URL"
  echo "AUD_URL=$AUD_URL"
  echo "IFN=$IFN"
  echo "AFN=$AFN"

  fetch() {
    SRC="$1"; OUT="$2"
    [ -z "$SRC" ] || [ -z "$OUT" ] && return 0
    # curl с редиректами и ретраями; fallback на wget
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 -o "$OUT" "$SRC"; then
      command -v wget >/dev/null 2>&1 && wget -q --tries=3 --timeout=60 -O "$OUT" "$SRC" || true
    fi
  }

  [ -n "$IMG_URL" ] && [ -n "$IFN" ] && fetch "$IMG_URL" "$INP/$IFN"
  [ -n "$AUD_URL" ] && [ -n "$AFN" ] && fetch "$AUD_URL" "$INP/$AFN"

  printf '{"image":"%s","audio":"%s"}\n' "$IFN" "$AFN" > "$INP/.inputs.json" 2>/dev/null || true
  ls -lah "$INP" || true
} >>"$LOGF" 2>&1