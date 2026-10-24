#!/bin/bash
# DNS-01 end to end: Caddy (this image) → backend acme-dns API → PowerDNS primary ← Pebble.
# Passes when Caddy serves a Pebble-issued cert covering <label> and *.<label>.
#   ./run.sh                     build the image under test from ../.. and the backend
#   CADDY_IMAGE=… ./run.sh       test an existing image
#   KEEP=1 ./run.sh              leave the stack up afterwards
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p work
export CADDY_IMAGE=${CADDY_IMAGE:-mesh-router-caddy:acmedns-local}
DC="docker compose"

if [ "$CADDY_IMAGE" = mesh-router-caddy:acmedns-local ]; then
  docker build -q -t "$CADDY_IMAGE" ../.. >/dev/null
fi

cleanup() {
  if [ -n "${ACME_USER:-}" ]; then
    $DC exec -T backend node --input-type=module -e "$NODE_FB
      await getFirestore().collection('nsl-router').doc('$ACME_USER').delete();" || true
  fi
  [ -n "${KEEP:-}" ] || $DC down -v --remove-orphans >/dev/null 2>&1
}
trap cleanup EXIT

$DC up -d --build pdns redis backend pebble
until $DC logs backend 2>&1 | grep -q "user zones on"; do sleep 1; done

# Throwaway user with a keypair: its signature is the acme-dns password.
NODE_FB="const { initializeFb } = await import('/app/dist/firebase/firebaseIntegration.js'); initializeFb();
const { getFirestore } = await import('firebase-admin/firestore');"
read -r ACME_USER ACME_KEY < <($DC exec -T -w /app backend node --input-type=module -e "$NODE_FB
  const { generateKeyPair, sign } = await import('/app/dist/library/KeyLib.js');
  const uid = 'dnszero' + Date.now().toString(36);
  const k = await generateKeyPair();
  await getFirestore().collection('nsl-router').doc(uid).set({
    domainName: uid, serverDomain: 'test.example.com', publicKey: k.pub });
  console.log(uid, await sign(k.priv, uid));
  process.exit(0);")
export ACME_USER ACME_KEY ACME_LABEL=$ACME_USER
echo "test user $ACME_USER"
# the admin path: delegation creates the zone (Caddy finds it by an SOA lookup)
$DC exec -T backend mesh-cli dns delegate "$ACME_USER" on

$DC cp pebble:/test/certs/pebble.minica.pem work/pebble.minica.pem
$DC up -d caddy

echo "waiting for the certificate…"
for _ in $(seq 1 90); do
  [ "$($DC logs caddy 2>&1 | grep -c "certificate obtained successfully")" -ge 2 ] && break
  if $DC logs caddy 2>&1 | grep -q "could not get certificate"; then break; fi
  sleep 2
done
$DC logs caddy 2>&1 | grep -E "solve challenge|obtained|\"level\":\"error\"" | sed 's/^caddy-1  | //' | cut -c1-220 || true
echo "--- backend"
$DC logs backend 2>&1 | grep -E "acme-dns|\[dns\]" | sed 's/^backend-1  | //' || true

ZONE="$ACME_LABEL.test.example.com"
echo "--- TXT on the primary"
$DC exec -T backend node -e "fetch('http://pdns:8081/api/v1/servers/localhost/zones/$ZONE.',{headers:{'X-API-Key':'testkey'}}).then(r=>r.json())
  .then(z=>z.rrsets.filter(r=>r.type==='TXT').forEach(r=>console.log(r.name, r.ttl, r.records.map(x=>x.content).join(' '))))"

echo "--- served certificate"
PEBBLE_ROOT=$($DC exec -T -e NODE_NO_WARNINGS=1 backend node -e "process.env.NODE_TLS_REJECT_UNAUTHORIZED='0';fetch('https://pebble:15000/roots/0').then(r=>r.text()).then(t=>process.stdout.write(t))")
printf '%s\n' "$PEBBLE_ROOT" > work/pebble-root.pem
ok=1
for name in "$ZONE" "app.$ZONE"; do
  out=$(docker run --rm --network caddy-dns01-test_net -v "$PWD/work:/w:ro" alpine/openssl s_client \
          -connect caddy:443 -servername "$name" -CAfile /w/pebble-root.pem -verify_hostname "$name" </dev/null 2>&1 || true)
  san=$(printf '%s' "$out" | sed -n '/BEGIN CERT/,/END CERT/p' | docker run --rm -i alpine/openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1)
  verify=$(printf '%s' "$out" | grep -m1 "Verify return code" || echo "no handshake")
  echo "$name: $verify | SAN$san"
  printf '%s' "$verify" | grep -q "0 (ok)" || ok=0
done

if [ "$ok" = 1 ]; then echo "PASS: wildcard + root issued over DNS-01 through the acme-dns API"; else echo "FAIL"; exit 1; fi
