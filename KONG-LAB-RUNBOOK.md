# Kong lab: Defender plug-in on the customer's Kong (VM 192.168.0.28, folder ~/cx-lab)

The idea in one line: the customer already runs Kong. We do not replace it. We add Cequence's plug-in
(`cequence-defender` + `libdefender_kong.so`) INSIDE their Kong, and restart Kong once.

```
you -> :8081 -> [ Kong (+ Defender plug-in) ] -> difi-app (the application)
                       |  background calls over HTTPS
                       v
                 UAP 192.168.0.18  (auth. = login, edge. = policies and telemetry)
```
Containers (project `kong-lab`, own network 172.31.0.0/24): `kong-difi-app` (same app as the nginx lab),
`kong-cx-dns` (same dnsmasq: *.uap.seekbank.com -> 192.168.0.18), `cx-kong` (Kong 3.11, DB-less).
The nginx lab (docker-compose.yml, port 8080) is separate and untouched.

## Done and tested (2026-11-02 night)
| Step | What | Test | Result |
|---|---|---|---|
| A | Plain Kong in front of difi-app | curl :8081 / /api/login /api/products /api/cart / nope | 200 x4, 404 from the app |
| B1 | Build `kong-with-defender:0.22.0` from the bundle Dockerfile | rock installed, .so has no missing libs | OK |
| B2 | Kong + plug-in, DUMMY credentials | plug-in loads, status page answers, app still 200 (fail-open) | OK |
| B3 | Real login to the UAP | needs the keycloak-ca + real client id/secret | NOT DONE (see below) |

Mistake on the way (kept on purpose): the generated config file was chmod 600, Kong runs as user `kong`, so it
said `Permission denied` reading it. Fixed with 644 (the file holds no secret).

## What I need from you to finish (3 things)
1. Client id and secret of the UAP client `edge-defender` (never in chat):
   ```
   cd ~/cx-lab && cp env.example .env 2>/dev/null || printf 'CEQUENCE_CLIENT_ID=\nCEQUENCE_CLIENT_SECRET=\n' > .env
   nano .env
   ```
2. The keycloak CA, taken on cqk8s-master (192.168.0.18), public cert only:
   ```
   kubectl get secret auth.uap.seekbank.com-tls -n cequence -o jsonpath='{.data.ca\.crt}' | base64 -d > keycloak-ca.crt
   scp keycloak-ca.crt cquser@192.168.0.28:~/cx-lab/uap-cas/
   ```
3. Then, on the VM:
   ```
   cd ~/cx-lab && ./kong-defender-up.sh
   ```
   It builds the trust file, writes kong/kong.defender.yml from the template, and restarts only cx-kong.

## Check it works
```
docker logs cx-kong 2>&1 | grep -i defender | tail          # no "token request failed"
curl -s localhost:8081/__end/status                           # policies_loaded > 0, shipper sent > 0
for i in 1 2 3; do curl -s localhost:8081/api/products; done  # then UAP -> Discovery: host/IP of the VM, /api/*
```
Back to plain Kong: `./kong-defender-up.sh --plain`. Turn `diagnostics` off in the template when done.

## Files
`docker-compose.kong.yml` (the lab) | `kong/kong.plain.yml` (before) | `kong/kong.defender.yml.tpl` (after) |
`kong-defender-up.sh` (switch) | `BUILD-LOG.md` (what I did, in order) | bundle on the VM: ~/defender-for-kong
