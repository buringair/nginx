# NGINX Routing Setup for the ABC SSO Traffic Flow

This project contains NGINX routing for the Windows 10 traffic flow and the Python origin service hosted on `10.0.10.9`.

## Design diagram

```text
Windows 10 Client
    |
    | 1) GET https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml
    | 2) POST https://sso-logging.lb.abc.cn/sso/log
    v
proxy1 (Ubuntu + NGINX)
    |
    | GET /config/1.2.1/ssoconf.xml  --> https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml
    | POST /sso/log                  --> https://cn-sso-config.lb.abc.com/sso/log
    v
proxy2 (Ubuntu + NGINX)
    |
    | GET /config/1.2.1/ssoconf.xml  --> https://sso-config.lb.abc.com/config/1.2.1/ssoconf.xml
    | POST /sso/log                  --> https://sso-logging.lb.abc.com/sso/log
    v
origin webserver (10.0.10.9)
```

## Components

- Windows 10 client: client device initiating the traffic
- proxy1: Ubuntu-based NGINX edge server listening on HTTPS port 443
- proxy2: internal Ubuntu-based NGINX routing proxy that enforces mTLS authentication
- sso-config.lb.abc.cn: external host for anonymous GET requests of the configuration XML
- sso-logging.lb.abc.cn: external host for log upload POST requests
- cn-sso-config.lb.abc.com: internal proxied endpoint used by proxy1 to send requests to proxy2 over HTTPS
- sso-config.lb.abc.com: origin endpoint that serves the XML configuration
- sso-logging.lb.abc.com: origin endpoint that accepts the log payload

## Exact server and URL names used in the flow

- Client: `Windows 10 client`
- Proxy 1: `proxy1` (Ubuntu + NGINX)
- Proxy 2: `proxy2` (Ubuntu + NGINX)
- External config URL: `https://sso-config.lb.abc.cn/config/1.2.1/ssoconf.xml`
- External logging URL: `https://sso-logging.lb.abc.cn/sso/log`
- Proxy1-to-proxy2 forwarding URL: `https://cn-sso-config.lb.abc.com/config/1.2.1/ssoconf.xml`
- Proxy1-to-proxy2 logging forwarding URL: `https://cn-sso-config.lb.abc.com/sso/log`
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
3. proxy1 routes the request to proxy2 over HTTPS at `https://cn-sso-config.lb.abc.com/sso/log` using mTLS authentication.
4. proxy2 forwards the request to `https://sso-logging.lb.abc.com/sso/log` without requiring mTLS to the final upstream.
5. The final upstream service accepts the log payload and responds with a success result.

## Security model

- TLS is enabled on the public web server endpoint and the proxy1-to-proxy2 connection.
- mTLS is required only between proxy1 and proxy2.
- proxy2 validates the origin certificate against the internal CA certificate installed at `/etc/nginx/certs/ca.crt` and uses the matching origin hostname for SNI.
- The Windows 10 client does not authenticate to proxy1; the GET is anonymous.
- Request routing is method- and URL-based so GET traffic for the XML configuration is routed only to the configuration endpoint and POST traffic to the log endpoint.

## Files in this project

- `configs/proxy1.conf`: public edge proxy configuration for `sso-config.lb.abc.cn` and `sso-logging.lb.abc.cn`
- `configs/proxy2.conf`: internal routing proxy configuration for `cn-sso-config.lb.abc.com`
- `configs/origin.conf`: HTTPS virtual host configuration for the origin on `10.0.10.9`
- `configs/origin-access.logrotate`: daily rotation for the separate origin access logs
- `sso_origin.py`: local Python origin for serving the XML file and recording POST bodies
- `configs/sso-origin.service`: systemd service unit for the local origin
- `configs/sso-origin.logrotate`: daily rotation policy for accepted log uploads
- `configs/certs/generate_certs.sh`: self-signed certificate generator for local testing
- `configs/certs/generate_origin_cert.sh`: origin certificate generator signed by the existing internal CA
- `configs/certs/`: all proxy certificates and trust material are stored here

## Local certificate generation

```bash
bash configs/certs/generate_certs.sh
```

Do not run the general certificate generator on a deployed system: it recreates the CA and proxy keys. To create only the origin certificate, use `sudo bash configs/certs/generate_origin_cert.sh`.

## Origin deployment

The origin on `10.0.10.9` serves `root/config/1.2.1/ssoconf.xml` for GET requests to `/config/1.2.1/ssoconf.xml`. POST requests to `/sso/log` accept JSON objects with string fields `filename` and `content`; `content` is stored as UTF-8 bytes under `root/bigquery/` using a unique UTC timestamp filename without an extension. The submitted filename is retained as metadata, not used as a filesystem path. Uploads are limited to 1 MiB. A private `sso-logs/uploads.jsonl` audit record stores each upload's original filename, stored filename, content type, size, and receive time.

Install NGINX on the origin host, then run the deployment script:

```bash
sudo apt update
sudo apt install -y nginx
sudo bash deploy-origin.sh
```

The script creates an origin server certificate from the existing internal CA if one is not already installed. The origin listens on HTTPS port 443 and proxies locally to the Python service on `127.0.0.1:8080`. It does not expose a port-80 listener. Config endpoint requests are written to `logs/sso-config_get_access.log`; logging endpoint requests are written to `logs/sso-logging_post_access.log`. Both files rotate daily and retain 14 compressed rotations.

Example logging request body:

```json
{"filename":"report.txt","content":"UTF-8 file contents"}
```

Each successful POST returns HTTP 204. The stored file is named with its UTC receive timestamp in `YYYYMMDDTHHMMSS.ffffffZ` format; if that name already exists, a numeric suffix is added.

After updating `configs/proxy2.conf`, deploy that configuration on `10.0.10.8` as well. Its existing deployment script installs `ca.crt` at `/etc/nginx/certs/ca.crt`, which the updated config uses to verify the origin certificate. The proxy hosts must resolve their upstream names to the intended addresses: proxy1 to proxy2 (`10.0.10.8`), and proxy2 to the origin (`10.0.10.9`).

## Notes

The proxy-facing certificates in this workspace are for local testing. Ensure each hostname resolves to the intended proxy or origin address, and distribute the internal CA certificate to systems that must trust the origin certificate.
