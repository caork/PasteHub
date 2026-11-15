package syncserver

import (
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
)

// KeyPrefix marks version 1 of the PasteHub sync key format.
const KeyPrefix = "phs1_"

// keySalt and the HKDF info labels must match PasteHubCore/Sync/SyncKeys.swift.
var keySalt = []byte("PasteHub sync v1")

// GenerateKey returns a new random sync key string and its 32-byte master secret.
func GenerateKey() (string, []byte, error) {
	master := make([]byte, 32)
	if _, err := rand.Read(master); err != nil {
		return "", nil, err
	}
	return FormatKey(master), master, nil
}

// FormatKey encodes a 32-byte master secret as a sync key string.
func FormatKey(master []byte) string {
	return KeyPrefix + base64.RawURLEncoding.EncodeToString(master)
}

// ParseKey decodes a sync key string into its 32-byte master secret.
func ParseKey(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, KeyPrefix) {
		return nil, errors.New("sync key must start with " + KeyPrefix)
	}
	master, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(s, KeyPrefix))
	if err != nil {
		return nil, err
	}
	if len(master) != 32 {
		return nil, errors.New("sync key must encode 32 bytes")
	}
	return master, nil
}

// DeriveAuthToken derives the bearer token a client sends to the server.
// The server never sees the master secret, only this token.
func DeriveAuthToken(master []byte) []byte {
	token, err := hkdf.Key(sha256.New, master, keySalt, "auth", 32)
	if err != nil {
		panic(err) // only fails for invalid lengths, which are constant here
	}
	return token
}

// SpaceIDForToken maps a bearer token to the space it unlocks.
// Only this hash is stored, so a database leak does not reveal usable tokens.
func SpaceIDForToken(token []byte) string {
	sum := sha256.Sum256(token)
	return hex.EncodeToString(sum[:])
}

// SpaceIDForKey is a convenience for administration commands.
func SpaceIDForKey(master []byte) string {
	return SpaceIDForToken(DeriveAuthToken(master))
}
