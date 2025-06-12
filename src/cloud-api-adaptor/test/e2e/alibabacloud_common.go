// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"testing"
	"time"

	ecs "github.com/alibabacloud-go/ecs-20140526/v4/client"
	pv "github.com/confidential-containers/cloud-api-adaptor/src/cloud-api-adaptor/test/provisioner/alibabacloud"
)

// AlibabaCloudAssert implements the CloudAssert interface for alibaba cloud.
type AlibabaCloudAssert struct{}

func NewAlibabaCloudAssert() *AlibabaCloudAssert {
	return &AlibabaCloudAssert{}
}

func (c AlibabaCloudAssert) DefaultTimeout() time.Duration {
	return 2 * time.Minute
}

// findVM is a helper function to find VMs bytheir prefix name.
func describeInstances(prefixName string) ([]*ecs.DescribeInstancesResponseBodyInstancesInstance, error) {
	cmd := exec.Command(pv.Cli, "ecs", "DescribeInstances", "--RegionId", pv.Region, "--InstanceName", "podvm-*")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to get instances: %v", err)
	}

	var response ecs.DescribeInstancesResponseBody
	err = json.Unmarshal(out, &response)
	if err != nil {
		return nil, fmt.Errorf("failed to parse DescribeInstancesResponse: %v", err)
	}

	if response.Instances != nil {
		return response.Instances.Instance, nil
	}

	return make([]*ecs.DescribeInstancesResponseBodyInstancesInstance, 0), nil
}

func isAlibabaCloudVMExisted(prefixName string) (bool, error) {
	instances, err := describeInstances(prefixName)
	if err != nil {
		return false, fmt.Errorf("failed to query instances: %v", err)
	}

	return len(instances) == 0, nil
}

func (c AlibabaCloudAssert) HasPodVM(t *testing.T, id string) {
	podVmPrefix := "podvm-" + id
	has, err := isAlibabaCloudVMExisted(podVmPrefix)
	if err != nil {
		t.Logf("Error happens when checking the VM: %v", err)
	}
	if has {
		t.Logf("VM %s found", id)
	} else {
		t.Logf("Virtual machine %s not found ", id)
		t.Error("PodVM was not created")
	}
}

func (c AlibabaCloudAssert) GetInstanceType(t *testing.T, podName string) (string, error) {
	// Get Instance Type of PodVM
	return "", nil
}
