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
    | POST /sso/log                  --> https://cn-sso-logging.lb.abc.com/sso/log
    v
proxy2 (Ubuntu + NGINX)
    |
    | GET /config/1.2.1/ssoconf.xml  --> https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml
    | POST /sso/log                  --> https://sso-logging.lb.abc.com/sso/log
    v
sso-config.lb.abc.com (GET) / sso-logging.lb.abc.com (POST)
```

## Components

- Windows 10 client: client device initiating the traffic
- proxy1: Ubuntu-based NGINX edge server listening on HTTPS port 443
- proxy2: internal Ubuntu-based NGINX routing proxy that enforces mTLS authentication
- sso-config.lb.abc.cn: external host for anonymous GET requests of the configuration XML
- sso-logging.lb.abc.cn: external host for log upload POST requests
- cn-sso-config.lb.abc.com: internal config endpoint used by proxy1 to send GET requests to proxy2 over HTTPS
- cn-sso-logging.lb.abc.com: internal logging endpoint used by proxy1 to send POST requests to proxy2 over HTTPS
- sso-config.lb.abc.com: final upstream server that serves the XML configuration
- sso-logging.lb.abc.com: final upstream server that accepts the log payload

## Exact server and URL names used in the flow

- Client: `Windows 10 client`
- Proxy 1: `proxy1` (Ubuntu + NGINX)
- Proxy 2: `proxy2` (Ubuntu + NGINX)
- External config URL: `https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml`
- External logging URL: `https://sso-logging.lb.abc.cn/sso/log`
- Proxy1-to-proxy2 forwarding URL: `https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml`
- Proxy1-to-proxy2 logging forwarding URL: `https://cn-sso-logging.lb.abc.com/sso/log`
- Final upstream config URL: `https://sso-config.lb.abc.com/config/1.2.1/ssoconf.xml`
- Final upstream logging URL: `https://sso-logging.lb.abc.com/sso/log`

## Workflow 1: Anonymous GET of the configuration file

1. The Windows 10 client sends an anonymous HTTPS GET to `https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml`.
2. The NGINX server on proxy1 listens on port 443 and accepts the HTTPS request without requiring the client certificate.
3. proxy1 routes the request to proxy2 over HTTPS at `https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml` using mTLS authentication.
4. proxy2 forwards the request to `https://sso-config.lb.abc.com/config/1.2.1/ssoconf.xml` without requiring mTLS to the final upstream.
5. The final upstream service returns the XML configuration payload.

## Workflow 2: POST upload log content

1. The Windows 10 client sends an HTTPS POST to `https://sso-logging.lb.abc.cn/sso/log` with the log content payload.
2. The NGINX server on proxy1 listens on port 443 and accepts the HTTPS request without requiring the client certificate.
3. proxy1 routes the request to proxy2 over HTTPS at `https://cn-sso-logging.lb.abc.com/sso/log` using mTLS authentication. The proxy2 certificate must include `cn-sso-logging.lb.abc.com` as a subject alternative name.
4. proxy2 forwards the request to `https://sso-logging.lb.abc.com/sso/log` without requiring mTLS to the final upstream.
5. The final upstream service accepts the log payload and responds with a success result.

## Security model

- TLS is enabled on the public web server endpoint and the proxy1-to-proxy2 connection.
- mTLS is required only between proxy1 and proxy2.
- The proxy2 server certificate must include both `cn-sso-config.lb.abc.com` and `cn-sso-logging.lb.abc.com` as subject alternative names; proxy1 validates it against the internal CA.
- proxy2 validates the final upstream's TLS certificate against `/etc/nginx/certs/ca/ca.crt` and sends the upstream hostname as SNI. The CA certificate and related CA material are stored in `configs/certs/ca/`.
- The Windows 10 client does not authenticate to proxy1; the GET is anonymous.
- Request routing is method- and URL-based so GET traffic for the XML configuration is routed only to the configuration endpoint and POST traffic to the log endpoint.

## Files in this project

- `configs/proxy1.conf`: public edge proxy configuration for `sso-config.lb.abc.cn` and `sso-logging.lb.abc.cn`
- `configs/proxy2.conf`: internal routing proxy configuration for `cn-sso-config.lb.abc.com` and `cn-sso-logging.lb.abc.com`
- `configs/certs/generate_certs.sh`: self-signed certificate generator for local testing
- `configs/certs/`: proxy certificates and keys
- `configs/certs/ca/`: CA certificate, private key, and serial file

## Local certificate generation

```bash
bash configs/certs/generate_certs.sh
```

The certificate-generation script preserves existing files in `configs/certs/ca/` and regenerates the proxy certificates using that CA. It creates a CA only when no CA files exist; if the CA directory is partially populated, it stops rather than replacing any CA files.

## Redeploying proxy2

Run the deployment script with root privileges:

```bash
sudo bash configs/scripts/deploy-proxy2.sh
```

The script preserves `configs/certs/ca/ca.crt`, `ca.key`, and `ca.srl`: it does not delete or rewrite those files. It contains the canonical `proxy2.conf` and recreates both `configs/proxy2.conf` and `/etc/nginx/conf.d/proxy2.conf`, as well as the proxy2 access/error log files, if they are missing. It generates a new proxy2 server certificate and key signed by the existing CA, validates the configuration, and reloads NGINX. If `/etc/nginx/certs/ca/ca.crt` already exists, it must exactly match the project CA certificate; the script refuses to replace a different installed CA. The script deploys proxy2 only and leaves `/etc/nginx/nginx.conf` and other NGINX sites untouched. The proxy1 config and client certificate must be managed separately.

## Notes

This config models the routing pattern described by the customer flow. In production, replace the self-signed certificates with real CA-issued certificates and ensure the hostnames resolve to the intended external and internal load balancers.
