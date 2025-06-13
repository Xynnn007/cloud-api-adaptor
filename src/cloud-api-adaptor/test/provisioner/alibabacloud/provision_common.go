// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package alibabacloud

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	pv "github.com/confidential-containers/cloud-api-adaptor/src/cloud-api-adaptor/test/provisioner"
	log "github.com/sirupsen/logrus"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
)

const (
	Cli         = "aliyun"
	OssBucket   = "peerpod-test"
	OssEndpoint = "https://oss-cn-beijing.aliyuncs.com"
	Region      = "cn-beijing"
)

var AlibabaCloudProps = &OnPremCluster{}

// Cluster defines create/delete/access interfaces to Kubernetes clusters
type Cluster interface {
	CreateCluster() error               // Create the Kubernetes cluster
	DeleteCluster() error               // Delete the Kubernetes cluster
	GetKubeconfigFile() (string, error) // Get the path to the kubeconfig file
}

// OnPremCluster represents an existing and running cluster
type OnPremCluster struct{}

// NewAlibabaCloudProvisioner instantiates the AlibabaCloud provisioner
// The AlibabaCloudProvisioner will use aliyun cli.
func NewAlibabaCloudProvisioner(properties map[string]string) (pv.CloudProvisioner, error) {
	_, err := exec.LookPath(Cli)
	if err != nil {
		return nil, fmt.Errorf("failed to get Alibaba Cloud CLI tool (aliyun): %v", err)
	}

	if properties["cluster_type"] == "" ||
		properties["cluster_type"] == "onprem" {
		provisioner := &OnPremCluster{}

		return provisioner, nil
	} else {
		return nil, fmt.Errorf("Cluster type '%s' not implemented",
			properties["cluster_type"])
	}
}

// CreateCluster does nothing as the cluster should exist already.
func (o *OnPremCluster) CreateCluster(ctx context.Context, cfg *envconf.Config) error {
	log.Info("On-prem cluster type selected. Nothing to do.")

	return nil
}

// DeleteCluster does nothing.
func (o *OnPremCluster) DeleteCluster(ctx context.Context, cfg *envconf.Config) error {
	log.Info("On-prem cluster type selected. Nothing to do.")

	return nil
}

// CreateVPC does nothing.
func (o *OnPremCluster) CreateVPC(ctx context.Context, cfg *envconf.Config) error {
	log.Info("On-prem cluster type selected. Nothing to do.")

	return nil
}

// DeleteVPC does nothing.
func (a *OnPremCluster) DeleteVPC(ctx context.Context, cfg *envconf.Config) error {
	log.Info("On-prem cluster type selected. Nothing to do.")
	return nil
}

func (a *OnPremCluster) GetProperties(ctx context.Context, cfg *envconf.Config) map[string]string {
	return map[string]string{}
}

func (a *OnPremCluster) UploadPodvm(imagePath string, ctx context.Context, cfg *envconf.Config) error {
	// Upload image to OSS
	file, err := os.Open(imagePath)
	if err != nil {
		return fmt.Errorf("failed to open image file: %v", err)
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		return fmt.Errorf("failed to get image file stat: %v", err)
	}
	key := stat.Name()
	cloudUrl := fmt.Sprintf("oss://%s/%s", OssBucket, key)
	err = a.uploadOss(imagePath, cloudUrl)
	if err != nil {
		return err
	}

	// Import image as Pod VM image
	err = a.importImage(key)
	if err != nil {
		return err
	}
	return nil
}

func (a *OnPremCluster) uploadOss(filepath string, cloudUrl string) error {
	cmd := exec.Command(Cli, "oss", "cp", filepath, cloudUrl, "-f")
	out, err := cmd.CombinedOutput()
	fmt.Printf("%s\n", out)
	if err != nil {
		return fmt.Errorf("failed to upload file to OSS: %v", err)
	}

	return nil
}

func (a *OnPremCluster) importImage(imageName string) error {
	cmd := exec.Command(Cli, "ecs", "ImportImage", "--ImageName", imageName, "--region", Region, "--RegionId", Region, "--BootMode", "UEFI", "--DiskDeviceMapping.1.OSSBucket", OssBucket, "--DiskDeviceMapping.1.OSSObject", imageName, "--Features.NvmeSupport", "supported", "--method", "POST", "--force")
	out, err := cmd.CombinedOutput()
	fmt.Printf("%s\n", out)
	if err != nil {
		return fmt.Errorf("failed to import image: %v", err)
	}
	return nil
}
