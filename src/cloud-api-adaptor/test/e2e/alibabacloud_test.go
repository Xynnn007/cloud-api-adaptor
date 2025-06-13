// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"testing"
)

func TestAlibabaCloudCreateSimplePod(t *testing.T) {
	assert := NewAlibabaCloudAssert()
	DoTestCreateSimplePod(t, testEnv, assert)
}

func TestAlibabaCloudCreatePodWithConfigMap(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePodWithConfigMap(t, testEnv, assert)
}

func TestAlibabaCloudCreatePodWithSecret(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePodWithSecret(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodContainerWithExternalIPAccess(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodContainerWithExternalIPAccess(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodWithJob(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodWithJob(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodAndCheckUserLogs(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodAndCheckUserLogs(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodAndCheckWorkDirLogs(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodAndCheckWorkDirLogs(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodAndCheckEnvVariableLogsWithImageOnly(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodAndCheckEnvVariableLogsWithImageOnly(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodAndCheckEnvVariableLogsWithDeploymentOnly(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodAndCheckEnvVariableLogsWithDeploymentOnly(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodAndCheckEnvVariableLogsWithImageAndDeployment(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodAndCheckEnvVariableLogsWithImageAndDeployment(t, testEnv, assert)
}

func TestAlibabaCloudCreatePeerPodWithLargeImage(t *testing.T) {
	assert := NewAlibabaCloudAssert()

	DoTestCreatePeerPodWithLargeImage(t, testEnv, assert)
}

func TestAlibabaCloudDeletePod(t *testing.T) {
	assert := NewAlibabaCloudAssert()
	DoTestDeleteSimplePod(t, testEnv, assert)
}

func TestAlibabaCloudCreateNginxDeployment(t *testing.T) {
	assert := NewAlibabaCloudAssert()
	DoTestNginxDeployment(t, testEnv, assert)
}

func TestAlibabaCloudPodWithInitContainer(t *testing.T) {
	assert := NewAlibabaCloudAssert()
	DoTestPodWithInitContainer(t, testEnv, assert)
}
