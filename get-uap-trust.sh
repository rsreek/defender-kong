#!/usr/bin/env bash
# get-uap-trust.sh - build the trust file the Defender plug-in needs for the UAP edge and auth hosts.
# For each host: fetch the certificate the server shows, find the CA that signed it (sent by the
# server, in --ca-dir, or already in the system list), verify strictly like nginx does
# (no partial chain, hostname checked), then write: system CA list + the extra CAs found.
#
# Usage:
#   get-uap-trust.sh --hosts edge.uap.example.com,auth.uap.example.com [options]
#
#   --hosts H1,H2      UAP hostnames the plug-in talks to (edge and auth)
#   --ip ADDR          connect to this IP instead of DNS (name still sent as SNI); e.g. the ingress IP
#   --port N           default 443
#   --ca-dir DIR       folder with CA certs you collected (*.crt / *.pem, any names): searched by subject
#   --out FILE         default ./ca-plus-uap.crt
#
# Exit code: 0 = every host verified OK, 1 = at least one host could not be verified, 2 = usage error.
# Only public certificates are read; no private key is ever needed.

set -uo pipefail

HOSTS= IP= PORT=443 CADIR= OUT=./ca-plus-uap.crt
die() { echo "ERROR: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) HOSTS=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --ca-dir) CADIR=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ -n "$HOSTS" ] || die "--hosts is required"
[ -z "$CADIR" ] || [ -d "$CADIR" ] || die "--ca-dir $CADIR is not a folder"
SYS=/etc/ssl/certs/ca-certificates.crt; [ -f "$SYS" ] || SYS=/etc/pki/tls/certs/ca-bundle.crt
[ -f "$SYS" ] || die "system CA bundle not found"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
subj() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }
iss()  { openssl x509 -in "$1" -noout -issuer  -nameopt RFC2253 | sed 's/^issuer=//'; }
fp()   { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# index the collected CA files by subject
: > "$W/cadir.idx"
if [ -n "$CADIR" ]; then
  i=0
  for f in "$CADIR"/*.crt "$CADIR"/*.pem; do
    [ -f "$f" ] || continue
    # a file may hold several certs: split them
    awk -v d="$W" -v b="cadir$i" '/BEGIN CERT/{p=1; n++; f=d"/"b"-"n".pem"} p{print > f} /END CERT/{p=0; close(f)}' "$f"
    for c in "$W"/cadir$i-*.pem; do
      [ -f "$c" ] && openssl x509 -in "$c" -noout 2>/dev/null && printf '%s\t%s\t%s\n' "$(subj "$c")" "$c" "$f" >> "$W/cadir.idx"
    done
    i=$((i+1))
  done
fi

ANCHORS=() FAIL=0
printf '\n%-32s %-8s %s\n' HOST RESULT "TRUSTED VIA"
IFS=, read -r -a HL <<< "$HOSTS"
for h in "${HL[@]}"; do
  d="$W/$h"; mkdir -p "$d"
  echo | timeout 10 openssl s_client -connect "${IP:-$h}:$PORT" -servername "$h" -showcerts 2>/dev/null \
    | awk -v d="$d" '/BEGIN CERT/{p=1; n++; f=d"/c"n".pem"} p{print > f} /END CERT/{p=0; close(f)}'
  if [ ! -f "$d/c1.pem" ]; then printf '%-32s %-8s %s\n' "$h" FAIL "no certificate (cannot connect to ${IP:-$h}:$PORT?)"; FAIL=1; continue; fi
  leaf="$d/c1.pem"
  cat "$d"/c*.pem > "$d/sent.pem"                       # everything the server sent = untrusted chain
  # 1. already trusted by the system list?
  if openssl verify -CAfile "$SYS" -untrusted "$d/sent.pem" -verify_hostname "$h" "$leaf" >/dev/null 2>&1; then
    printf '%-32s %-8s %s\n' "$h" OK "system CA list (public / company CA already installed)"; continue
  fi
  # 2. walk up from the leaf: self-signed top, a CA the server sent, or one in --ca-dir
  cur="$leaf" anchor= via=
  for _ in 1 2 3 4 5 6; do
    s=$(subj "$cur"); is=$(iss "$cur")
    if [ "$s" = "$is" ]; then anchor="$cur"; via="self-signed: $s"; break; fi
    next=
    for c in "$d"/c*.pem; do [ "$(subj "$c")" = "$is" ] && [ "$c" != "$cur" ] && next="$c" && break; done
    if [ -z "$next" ]; then
      m=$(awk -F'\t' -v s="$is" '$1==s{print $2"\t"$3; exit}' "$W/cadir.idx")
      if [ -n "$m" ]; then anchor=${m%%$'\t'*}; via="$is (file ${m#*$'\t'})"; break; fi
      break
    fi
    cur="$next"
  done
  if [ -z "$anchor" ]; then
    printf '%-32s %-8s %s\n' "$h" FAIL "issuer '$is' not sent by the server and not in --ca-dir"
    FAIL=1; continue
  fi
  # 3. strict check, like nginx: only the anchor is trusted, hostname must match
  if r=$(openssl verify -CAfile "$anchor" -untrusted "$d/sent.pem" -verify_hostname "$h" "$leaf" 2>&1); then
    printf '%-32s %-8s %s\n' "$h" OK "$via"
    ANCHORS+=("$anchor")
  else
    printf '%-32s %-8s %s\n' "$h" FAIL "$(echo "$r" | grep -m1 -E 'error' || echo "$r" | tail -1)"
    FAIL=1
  fi
done

# write the trust file: system list + each extra CA once
cp "$SYS" "$W/out.pem"; seen=
for a in "${ANCHORS[@]+"${ANCHORS[@]}"}"; do
  f=$(fp "$a"); case " $seen " in *" $f "*) continue ;; esac
  seen="$seen $f"; cat "$a" >> "$W/out.pem"
  echo "   + added CA: $(subj "$a")  (until $(openssl x509 -in "$a" -noout -enddate | cut -d= -f2))"
done
cp "$W/out.pem" "$OUT"
echo "   trust file: $OUT ($(grep -c 'BEGIN CERTIFICATE' "$OUT") certs)"

if [ "$FAIL" = 1 ]; then
  echo
  echo "Not every host verified. Get the CA that signed it and put it in --ca-dir, e.g. on a UAP cluster"
  echo "(public CA cert only, never tls.key):"
  echo "  kubectl get secret <auth-host>-tls -n cequence -o jsonpath='{.data.ca\\.crt}' | base64 -d > keycloak-ca.crt"
  exit 1
fi
echo "All hosts verified. Use it in nginx: lua_ssl_trusted_certificate <path to $(basename "$OUT")>;"
