// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package utils

import (
	"os"
	"strings"
)

// RewriteImageRef rewrites container image references for private-registry testing.
//
// Controlled by environment variable E2E_IMAGE_REWRITE, a comma-separated list of
// oldPrefix=newPrefix rules. First matching prefix wins.
//
// Example:
//
//	E2E_IMAGE_REWRITE="quay.io/confidential-containers=ghcr.io/my-org,quay.io/kata-containers=ghcr.io/my-org,quay.io/prometheus=ghcr.io/my-org,quay.io/curl=ghcr.io/my-org,ghcr.io/kata-containers=ghcr.io/my-org"
func RewriteImageRef(image string) string {
	rules := os.Getenv("E2E_IMAGE_REWRITE")
	if rules == "" || image == "" {
		return image
	}
	for _, rule := range strings.Split(rules, ",") {
		rule = strings.TrimSpace(rule)
		if rule == "" {
			continue
		}
		parts := strings.SplitN(rule, "=", 2)
		if len(parts) != 2 {
			continue
		}
		from := strings.TrimSpace(parts[0])
		to := strings.TrimSpace(parts[1])
		if from == "" || to == "" {
			continue
		}
		if strings.HasPrefix(image, from) {
			return to + strings.TrimPrefix(image, from)
		}
	}
	return image
}
