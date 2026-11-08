# NGINX Routing Setup for the ABC SSO Traffic Flow

This repository contains the NGINX routing design for the exact Windows 10 traffic flows provided by the client.

## Design diagram

```text
Windows 10 Client
    |
    | 1) GET https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml
    | 2) POST https://sso-logging.lb.abc.cn/sso/log
    v
proxy1 (Ubuntu + NGINX)
    |
    | GET /config/1.2.1/ssoconf.xml  --> https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml
    | POST /sso/log                  --> https://sso-config.lb.abc.cn/sso/log
    v
proxy2 (Ubuntu + NGINX)
    |
    | GET /config/1.2.1/ssoconf.xml  --> https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml
    | POST /sso/log                  --> https://cn-sso-config.lb.abc.com/sso/log
    v
sso-config.lb.abc.com
```

## Components

- Windows 10 client: client device initiating the traffic
- proxy1: Ubuntu-based NGINX edge server listening on HTTPS port 443
- proxy2: internal Ubuntu-based NGINX routing proxy that enforces mTLS authentication
- sso-config.lb.abc.cn: external host for anonymous GET requests of the configuration XML
- sso-logging.lb.abc.cn: external host for log upload POST requests
- cn-sso-config.lb.abc.com: internal proxied endpoint used by proxy1 to send requests to proxy2 over HTTPS
- sso-config.lb.abc.com: final upstream server that serves the XML configuration and accepts the log payload

## Exact server and URL names used in the flow

- Client: `Windows 10 client`
- Proxy 1: `proxy1` (Ubuntu + NGINX)
- Proxy 2: `proxy2` (Ubuntu + NGINX)
- External config URL: `https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml`
- External logging URL: `https://sso-logging.lb.abc.cn/sso/log`
- Proxy1-to-proxy2 forwarding URL: `https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml`
- Proxy1-to-proxy2 logging forwarding URL: `https://cn-sso-config.lb.abc.com/sso/log`
- Final upstream config URL: `https://sso-config.lb.abc.com/config/1.2.1/ssoconf.xml`
- Final upstream logging URL: `https://sso-config.lb.abc.com/sso/log`

## Workflow 1: Anonymous GET of the configuration file

1. The Windows 10 client sends an anonymous HTTPS GET to `https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml`.
2. The NGINX server on proxy1 listens on port 443 and accepts the HTTPS request without requiring the client certificate.
3. proxy1 routes the request to proxy2 over HTTPS at `https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml` using mTLS authentication.
4. proxy2 forwards the request to `https://sso-config.lb.abc.com/config/1.2.1/ssoconf.xml` without requiring mTLS to the final upstream.
5. The final upstream service returns the XML configuration payload.

## Workflow 2: POST upload log content

1. The Windows 10 client sends an HTTPS POST to `https://sso-logging.lb.abc.cn/sso/log` with the log content payload.
2. The NGINX server on proxy1 listens on port 443 and accepts the HTTPS request without requiring the client certificate.
3. proxy1 routes the request to proxy2 over HTTPS at `https://cn-sso-config.lb.abc.com/sso/log` using mTLS authentication.
4. proxy2 forwards the request to `https://sso-config.lb.abc.com/sso/log` without requiring mTLS to the final upstream.
5. The final upstream service accepts the log payload and responds with a success result.

## Security model

- TLS is enabled on the public web server endpoint and the proxy1-to-proxy2 connection.
- mTLS is required only between proxy1 and proxy2.
- proxy2 validates the final upstream's TLS certificate against the host's system CA bundle and sends the upstream hostname as SNI.
- The Windows 10 client does not authenticate to proxy1; the GET is anonymous.
- Request routing is method- and URL-based so GET traffic for the XML configuration is routed only to the configuration endpoint and POST traffic to the log endpoint.

## Files in this project

- `configs/proxy1.conf`: public edge proxy configuration for `sso-config.lb.abc.cn` and `sso-logging.lb.abc.cn`
- `configs/proxy2.conf`: internal routing proxy configuration for `cn-sso-config.lb.abc.com`
- `configs/certs/generate_certs.sh`: self-signed certificate generator for local testing
- `configs/certs/`: proxy leaf certificates and keys
- `configs/certs/ca/`: CA certificate, private key, and serial file; keep all CA files here
- `configs/scripts/deploye-proxy1.sh`: validates and deploys the proxy1 NGINX config

## Local certificate generation

```bash
bash configs/certs/generate_certs.sh
```

The certificate generator uses the existing CA under `configs/certs/ca/` and does not create, replace, or delete the CA certificate or private key. OpenSSL stores and updates the CA serial file in that same directory when issuing leaf certificates. Keep the CA private key protected and do not deploy it to NGINX.

## Notes

This config models the routing pattern described by the customer flow. In production, replace the self-signed certificates with real CA-issued certificates and ensure the hostnames resolve to the intended external and internal load balancers.
