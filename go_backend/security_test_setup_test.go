package gobackend

import "encoding/base64"

func init() {
	// Production receives this key from platform secure storage before the
	// extension system starts. Tests install a deterministic process-local key.
	key := make([]byte, extensionStorageMasterKeyBytes)
	for index := range key {
		key[index] = byte(index + 1)
	}
	if err := SetExtensionStorageMasterKey(base64.StdEncoding.EncodeToString(key)); err != nil {
		panic(err)
	}
}
