// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package alibabacloud

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	pv "github.com/confidential-containers/cloud-api-adaptor/src/cloud-api-adaptor/test/provisioner"
	log "github.com/sirupsen/logrus"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
)

const (
	Cli                         = "aliyun"
	AlibabaCloudCredentialsFile = "alibabacloud-cred.env"
)

var AlibabaCloudProps = &OnPremCluster{}

// Cluster defines create/delete/access interfaces to Kubernetes clusters
type Cluster interface {
	CreateCluster() error               // Create the Kubernetes cluster
	DeleteCluster() error               // Delete the Kubernetes cluster
	GetKubeconfigFile() (string, error) // Get the path to the kubeconfig file
}

// OnPremCluster represents an existing and running cluster
type OnPremCluster struct {
	PodVMImageId    string
	Region          string
	RrsaRoleArn     string
	RrsaProviderArn string
	OssBucket       string
	OssEndpoint     string
	CaaImage        string
}

// NewAlibabaCloudProvisioner instantiates the AlibabaCloud provisioner
// The AlibabaCloudProvisioner will use aliyun cli.
func NewAlibabaCloudProvisioner(properties map[string]string) (pv.CloudProvisioner, error) {
	_, err := exec.LookPath(Cli)
	if err != nil {
		return nil, fmt.Errorf("failed to get Alibaba Cloud CLI tool (aliyun): %v", err)
	}

	if properties["cluster_type"] == "" ||
		properties["cluster_type"] == "onprem" {
		AlibabaCloudProps = &OnPremCluster{
			PodVMImageId:    properties["pod_vm_image_id"],
			Region:          properties["region"],
			RrsaRoleArn:     properties["rrsa_role_arn"],
			RrsaProviderArn: properties["rrsa_provider_arn"],
			OssBucket:       properties["oss_bucket"],
			OssEndpoint:     properties["oss_endpoint"],
			CaaImage:        properties["caa_image"],
		}

		return AlibabaCloudProps, nil
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
	props := map[string]string{
		"pod_vm_image_id":   a.PodVMImageId,
		"region":            a.Region,
		"rrsa_role_arn":     a.RrsaRoleArn,
		"rrsa_provider_arn": a.RrsaProviderArn,
		"oss_bucket":        a.OssBucket,
		"oss_endpoint":      a.OssEndpoint,
	}

	return props
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
	// Execute the command `git rev-parse HEAD` to get git rev
	cmd := exec.Command("git", "rev-parse", "HEAD")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to get current git rev: %v", err)
	}

	// Convert the output to string and trim any whitespace/newline characters
	commitHash := strings.TrimSpace(string(output))

	currentTime := time.Now()
	timestampSec := currentTime.Unix()

	imageName := fmt.Sprintf("%s-%s-%d", key, commitHash, timestampSec)

	cloudUrl := fmt.Sprintf("oss://%s/%s", a.OssBucket, imageName)
	err = a.uploadOss(imagePath, cloudUrl)
	if err != nil {
		return err
	}

	// Import image as Pod VM image
	err = a.importImage(imageName)
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

type ImportImageResponse struct {
	RequestId string
	ImageId   string
	TaskId    string
	RegionId  string
}

func (a *OnPremCluster) importImage(imageName string) error {
	cmd := exec.Command(Cli, "ecs", "ImportImage", "--ImageName", imageName, "--region", a.Region, "--RegionId", a.Region, "--BootMode", "UEFI", "--DiskDeviceMapping.1.OSSBucket", a.OssBucket, "--DiskDeviceMapping.1.OSSObject", imageName, "--Features.NvmeSupport", "supported", "--method", "POST", "--force")
	out, err := cmd.CombinedOutput()
	fmt.Printf("%s\n", string(out))
	if err != nil {
		return fmt.Errorf("failed to import image: %v", err)
	}

	var r ImportImageResponse
	err = json.Unmarshal(out, &r)
	if err != nil {
		return fmt.Errorf("failed to parse import image response: %v", err)
	}

	a.PodVMImageId = r.ImageId
	return nil
}

type AlibabaCloudInstallOverlay struct {
	Overlay *pv.KustomizeOverlay
}

func createRRSACredentialFile(dir, roleArn, providerArn string) error {
	content := fmt.Sprintf("ALIBABA_CLOUD_ROLE_ARN=%s\nALIBABA_CLOUD_OIDC_PROVIDER_ARN=%s\nALIBABA_CLOUD_OIDC_TOKEN_FILE=/var/run/secrets/ack.alibabacloud.com/rrsa-tokens/token", roleArn, providerArn)
	err := os.WriteFile(filepath.Join(dir, AlibabaCloudCredentialsFile), []byte(content), 0666)
	if err != nil {
		return nil
	}

	return nil
}

func NewAlibabaCloudInstallOverlay(installDir, provider string) (pv.InstallOverlay, error) {
	overlayDir := filepath.Join(installDir, "overlays", provider)

	// The credential file should exist in the overlay directory otherwise kustomize fails
	// to load it. At this point we don't know the key id nor access key, so using empty
	// values (later the file will be re-written properly).
	err := createRRSACredentialFile(overlayDir, AlibabaCloudProps.RrsaRoleArn, AlibabaCloudProps.RrsaProviderArn)
	if err != nil {
		return nil, err
	}

	overlay, err := pv.NewKustomizeOverlay(overlayDir)
	if err != nil {
		return nil, err
	}

	return &AlibabaCloudInstallOverlay{
		Overlay: overlay,
	}, nil
}

func (a *AlibabaCloudInstallOverlay) Apply(ctx context.Context, cfg *envconf.Config) error {
	return a.Overlay.Apply(ctx, cfg)
}

func (a *AlibabaCloudInstallOverlay) Delete(ctx context.Context, cfg *envconf.Config) error {
	return a.Overlay.Delete(ctx, cfg)
}

func (a *AlibabaCloudInstallOverlay) Edit(ctx context.Context, cfg *envconf.Config, properties map[string]string) error {
	var err error

	image := strings.Split(properties["caa_image"], ":")[0]
	tag := strings.Split(properties["caa_image"], ":")[1]
	log.Infof("Updating caa image with %s", image)
	if image != "" {
		err = a.Overlay.SetKustomizeImage("cloud-api-adaptor", "newName", image)
		if err != nil {
			return fmt.Errorf("failed to set CAA image name: %v", err)
		}
	}
	if tag != "" {
		err = a.Overlay.SetKustomizeImage("cloud-api-adaptor", "newTag", tag)
		if err != nil {
			return fmt.Errorf("failed to set CAA image tag: %v", err)
		}
	}

	// Mapping the internal properties to ConfigMapGenerator properties.
	mapProps := map[string]string{
		"pod_vm_image_id": "IMAGEID",
		"region":          "REGION",
	}

	for k, v := range mapProps {
		if properties[k] != "" {
			if err = a.Overlay.SetKustomizeConfigMapGeneratorLiteral("peer-pods-cm",
				v, properties[k]); err != nil {
				return err
			}
		}
	}

	if err = a.Overlay.YamlReload(); err != nil {
		return err
	}

	return nil
}
