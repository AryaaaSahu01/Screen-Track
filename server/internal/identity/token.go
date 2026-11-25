package identity

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
)

func NewToken() string {
	var raw [32]byte
	rand.Read(raw[:])
	return base64.RawURLEncoding.EncodeToString(raw[:])
}

func Hashtoken(token string) []byte {
	if len(token) != 43 {
		return nil
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(token)
	if err != nil || len(raw) != 32 {
		return nil
	}
	digest := sha256.Sum256(raw)
	return digest[:]
}

func FlowSecrets(state, browser string) (verifier, nonce string) {
	derive := func(label string) string {
		digest := sha256.Sum256([]byte("screen-track:oidc" + label + ":" + state + ":" + browser))
		return base64.RawStdEncoding.EncodeToString(digest[:])
	}
	return derive("pkce"), derive("nonce")
}
