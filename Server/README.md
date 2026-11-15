# pastehub-sync

End-to-end encrypted relay for PasteHub clipboard sync. It runs as a single Go
binary with SQLite and a blob directory, and it only ever sees ciphertext. The
protocol is in [docs/sync-protocol.md](../docs/sync-protocol.md).

## Commands

```bash
pastehub-sync serve  -data /var/lib/pastehub-sync -addr 127.0.0.1:9021
pastehub-sync keygen -data /var/lib/pastehub-sync -label NAME   # prints a new sync key once
pastehub-sync spaces -data /var/lib/pastehub-sync               # list spaces
pastehub-sync revoke -data /var/lib/pastehub-sync SPACE_ID      # delete a space and its data
```

On the server, run admin commands as the service user so file ownership stays correct:
`runuser -u pastehub-sync -- pastehub-sync keygen -data /var/lib/pastehub-sync -label kevin`.

## Test

```bash
cd Server && go test -race ./...
zsh Scripts/sync-e2e.sh      # Swift clients against a throwaway local relay
```

## Production deployment (gomami)

| Item | Value |
|---|---|
| URL | `https://paste.hawkingrad.com` |
| DNS | Cloudflare A record `paste` → `23.148.204.228`, proxy off (grey cloud) |
| TLS | certbot `dns-cloudflare`, `/etc/letsencrypt/live/paste.hawkingrad.com/` |
| Ingress | nginx stream SNI map `paste.hawkingrad.com 127.0.0.1:5251` → TLS site [`deploy/paste.hawkingrad.com.nginx`](deploy/paste.hawkingrad.com.nginx) → `127.0.0.1:9021` |
| Service | [`deploy/pastehub-sync.service`](deploy/pastehub-sync.service), user `pastehub-sync`, data `/var/lib/pastehub-sync` |
| Binary | `/usr/local/bin/pastehub-sync` |

This uses the same direct path as `pan.hawkingrad.com`. Do not route it through
gomami's `cloudflared`, which must stay disabled while zoro is the production
connector. The stream map shares :443 with sing-box REALITY: back up
`/etc/nginx/nginx.conf` and run `nginx -t` before every reload.

Upgrade:

```bash
cd Server && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(git rev-parse --short HEAD)" -o /tmp/pastehub-sync-linux ./cmd/pastehub-sync
scp -P 53111 /tmp/pastehub-sync-linux root@23.148.204.228:/tmp/
ssh -p 53111 root@23.148.204.228 'install -m 0755 /tmp/pastehub-sync-linux /usr/local/bin/pastehub-sync && systemctl restart pastehub-sync && curl -s 127.0.0.1:9021/v1/health'
```

No backup is kept. Every device holds its full history, so losing the relay
only loses catch-up for offline devices. To rebuild, redeploy, run `keygen`
again, and enter the new key on each device.

Removal order: delete the DNS record, remove the stream map line and the site
(`nginx -t && systemctl reload nginx`), `systemctl disable --now pastehub-sync`,
then delete `/var/lib/pastehub-sync`.
