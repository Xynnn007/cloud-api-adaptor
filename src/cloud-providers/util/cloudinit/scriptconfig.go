// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package cloudinit

import (
	"bytes"
	"fmt"
	"strings"
)

// ScriptConfig generates a shell script user-data payload. Private-cloud
// deployments often deliver user-data as a script rather than cloud-config
// write_files; the guest process-user-data binary executes it on boot.
type ScriptConfig struct {
	WriteFiles []WriteFile
}

const scriptHeader = `#!/bin/bash
set -eu
mkdir -p /run/peerpod
`

// Generate returns a bash script that writes peer-pod config files under
// /run/peerpod using heredocs.
func (config *ScriptConfig) Generate() (string, error) {
	var buf bytes.Buffer
	buf.WriteString(scriptHeader)

	for i, wf := range config.WriteFiles {
		if wf.Path == "" {
			return "", fmt.Errorf("write_files[%d]: path is required", i)
		}
		delimiter := fmt.Sprintf("CAA_PEERPOD_EOF_%d", i)
		buf.WriteString(fmt.Sprintf("cat > %q <<'%s'\n", wf.Path, delimiter))
		buf.WriteString(wf.Content)
		if len(wf.Content) > 0 && !strings.HasSuffix(wf.Content, "\n") {
			buf.WriteByte('\n')
		}
		buf.WriteString(delimiter + "\n")
	}

	return buf.String(), nil
}
