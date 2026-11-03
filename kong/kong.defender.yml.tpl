# Kong + Defender: the customer's service and route (as in kong.plain.yml) plus the cequence-defender plug-in,
# enabled globally. kong-defender-up.sh fills the ${...} values from ~/cx-lab/.env into kong/kong.defender.yml
# (not committed). The secret never goes into this file: it is a Kong vault reference to the env var
# CEQUENCE_CLIENT_SECRET that docker-compose passes to the container.
_format_version: "3.0"
services:
  - name: difi-app
    url: http://difi-app:80
    routes:
      - name: difi-app-all
        paths: ["/"]
        protocols: ["http", "https"]
plugins:
  - name: cequence-defender
    config:
      edge_url: https://edge.uap.seekbank.com
      auth_url: https://auth.uap.seekbank.com/auth/realms/cequence/protocol/openid-connect/token
      client_id: ${CEQUENCE_CLIENT_ID}
      client_secret: "{vault://env/cequence-client-secret}"
      instance_id: cx-kong-demo
      pool_id: kong
      diagnostics: true        # serves /__end/status while we check; turn off afterwards
