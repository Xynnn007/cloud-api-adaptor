// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package cloudinit

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestScriptUserData(t *testing.T) {
	const initdataContent = "gzip+base64-initdata-blob"
	scriptConfig := &ScriptConfig{
		WriteFiles: []WriteFile{
			{Path: "/run/peerpod/apf.json", Content: `{"pod-name":"test"}` + "\n"},
			{Path: "/run/peerpod/initdata", Content: initdataContent},
		},
	}

	userData, err := scriptConfig.Generate()
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}

	if !strings.HasPrefix(userData, "#!/bin/bash") {
		t.Fatalf("expected bash shebang, got: %q", userData[:min(20, len(userData))])
	}

	tmpDir := t.TempDir()
	apfPath := filepath.Join(tmpDir, "apf.json")
	initdataPath := filepath.Join(tmpDir, "initdata")

	// Rewrite paths to temp dir so the test does not need root.
	testScript := strings.ReplaceAll(userData, "/run/peerpod/apf.json", apfPath)
	testScript = strings.ReplaceAll(testScript, "/run/peerpod/initdata", initdataPath)
	testScript = strings.ReplaceAll(testScript, "mkdir -p /run/peerpod", "true")

	scriptFile := filepath.Join(tmpDir, "userdata.sh")
	if err := os.WriteFile(scriptFile, []byte(testScript), 0700); err != nil {
		t.Fatalf("write script: %v", err)
	}

	cmd := exec.Command("/bin/bash", scriptFile)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("run script: %v\n%s", err, out)
	}

	apfBytes, err := os.ReadFile(apfPath)
	if err != nil {
		t.Fatalf("read apf.json: %v", err)
	}
	if !strings.Contains(string(apfBytes), `"pod-name":"test"`) {
		t.Fatalf("unexpected apf.json: %s", apfBytes)
	}

	initdataBytes, err := os.ReadFile(initdataPath)
	if err != nil {
		t.Fatalf("read initdata: %v", err)
	}
	if strings.TrimSpace(string(initdataBytes)) != initdataContent {
		t.Fatalf("unexpected initdata: %q", initdataBytes)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
