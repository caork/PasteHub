# PasteHub sync protocol v1

PasteHub syncs clipboard history between devices through a small relay
(`Server/`). The relay stores and forwards ciphertext only. Sync is off until a
client is given a **server address** and a **sync key**; there are no accounts.

Client code: `Sources/PasteHubCore/Sync/`. Server code: `Server/internal/syncserver/`.

## Sync key

A sync key is `phs1_` followed by 32 random bytes in unpadded base64url
(48 characters in total). It is created on the server with
`pastehub-sync keygen`, which registers the matching space and prints the key
once. The server never stores the key.

Every device that holds the same key belongs to the same space. Removing a
space (`pastehub-sync revoke`) cuts off all of its devices.

Three keys are derived from the 32-byte master with HKDF-SHA256,
salt `"PasteHub sync v1"`:

| info | Use |
|---|---|
| `auth` | 32-byte bearer token, sent hex-encoded. The server stores `SHA-256(token)` as the space ID. |
| `enc` | ChaCha20-Poly1305 key for op payloads. |
| `mac` | HMAC-SHA256 key for item keys. |

The cross-language test vector (master = bytes `00..1f`) lives in
`Server/internal/syncserver/server_test.go` and `Tests/PasteHubCoreTests/SyncTests.swift`.

## HTTP API

All endpoints except `/v1/health` need `Authorization: Bearer <hex token>`. Unknown tokens get `401`.

| Method and path | Purpose |
|---|---|
| `GET /v1/health` | `{"ok":true,"version":"…"}` |
| `GET /v1/space` | `latestSeq`, `horizonSeq`, `blobBytes`, `quotaBytes` |
| `POST /v1/ops` | Append 1–200 ops. Idempotent by `opId`. Returns `{"results":[{"opId","seq"}]}` |
| `GET /v1/ops?after=N&limit=500` | Ops with `seq > N`, oldest first: `{"ops":[…],"hasMore":bool,"resetRequired":bool}` |
| `GET /v1/stream` | WebSocket. The server sends `{"latestSeq":N}` on connect and after every append |
| `PUT /v1/blobs/{id}` | Upload an encrypted blob, at most 5 MiB + 4 KiB. Re-upload is a no-op |
| `GET /v1/blobs/{id}` | Download an encrypted blob |

Errors are `{"error":"…"}` with `400` (validation), `409` (op references a
blob that was not uploaded), `413` (too large) or `507` (space quota of 500 MB
reached).

## Ops

```json
{
  "seq": 1024,
  "opId": "client UUID",
  "deviceId": "client UUID",
  "type": "upsert | pin | delete",
  "itemKey": "hex HMAC-SHA256(mac, contentHash)",
  "keep": true,
  "sealed": "base64 ChaCha20-Poly1305 combined box",
  "blobIds": ["…"]
}
```

- `seq` is assigned by the server and is the only ordering. Last writer wins.
- `itemKey` lets the server compact per item without learning the content hash.
- `keep` is set while the item is pinned, so retention keeps it.
- The AEAD associated data is `pastehub-op-v1|<opId>|<type>|<itemKey>`. After
  opening, clients check that `itemKey` matches the `contentHash` inside.

Sealed JSON (dates are milliseconds since 1970):

```json
{
  "contentHash": "sha256 of the plain text or PNG",
  "pinned": true,
  "upsert": {
    "kind": "text", "preview": "…", "createdAt": 0, "usedAt": 0, "pinned": false,
    "sourceAppName": "Safari", "deviceName": "Kevin's Mac",
    "representations": [
      {"uti": "public.utf8-plain-text", "data": "base64"},
      {"uti": "public.png", "blob": {"id": "uuid", "key": "base64 32 bytes", "size": 123456}}
    ]
  }
}
```

`pinned` is used by `pin` ops; `upsert` is set only for upsert ops. Representations up
to 32 KiB are inline. Larger ones are uploaded first as blobs, each sealed with
its own random key carried in the op.

## Client rules

- Local edits (`ingest`, pin, delete) write to `syncOutbox` in the same
  transaction, only while sync is configured. Applying a remote op never writes
  to the outbox.
- Clips whose representations (excluding the thumbnail) exceed **5 MiB** are not
  uploaded and are marked `tooLarge`.
- History-limit eviction and "clear history" stay local.
- A device skips its own ops when pulling and stores its cursor per space.
  On `resetRequired` it pulls again from 0; applying ops is idempotent.
- Remote upserts never move `lastUsedAt` backwards.

## Retention (hourly)

1. Superseded ops are removed: everything before a `delete` of the same item,
   older `upsert`s, and `pin`s older than the latest `upsert` or `pin`.
2. Ops older than 30 days are removed unless the item's newest op has
   `keep`. `horizonSeq` advances so lagging clients get `resetRequired`.
3. Blobs not referenced by any remaining op are removed after one hour.
