// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package cloudinit

import "fmt"

const (
	// UserDataFormatCloudConfig is the upstream default (#cloud-config write_files).
	UserDataFormatCloudConfig = "cloud-config"
	// UserDataFormatScript emits a bash script that writes files under /run/peerpod.
	UserDataFormatScript = "script"
)

// NewUserDataGenerator returns a generator for the requested user-data format.
func NewUserDataGenerator(format string, files []WriteFile) (CloudConfigGenerator, error) {
	switch format {
	case "", UserDataFormatCloudConfig:
		return &CloudConfig{WriteFiles: files}, nil
	case UserDataFormatScript:
		return &ScriptConfig{WriteFiles: files}, nil
	default:
		return nil, fmt.Errorf("unsupported user-data format %q (use %q or %q)",
			format, UserDataFormatCloudConfig, UserDataFormatScript)
	}
}
