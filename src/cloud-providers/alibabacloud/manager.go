// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package alibabacloud

import (
	"flag"

	provider "github.com/confidential-containers/cloud-api-adaptor/src/cloud-providers"
)

var alibabacloudcfg Config

type Manager struct{}

func init() {
	provider.AddCloudProvider("alibabacloud", &Manager{})
}

func (*Manager) ParseCmd(flags *flag.FlagSet) {
	reg := provider.NewFlagRegistrar(flags)

	// Flags with environment variable support
	reg.StringWithEnv(&alibabacloudcfg.AccessKeyID, "alibabacloud-access-key-id", "", "ALIBABACLOUD_ACCESS_KEY_ID", "Access Key ID", provider.Secret())
	reg.StringWithEnv(&alibabacloudcfg.SecretKey, "alibabacloud-secret-access-key", "", "ALIBABACLOUD_ACCESS_KEY_SECRET", "Secret Key", provider.Secret())
	reg.StringWithEnv(&alibabacloudcfg.Region, "region", "cn-beijing", "REGION", "Region")
	reg.StringWithEnv(&alibabacloudcfg.EcsEndpoint, "ecs-endpoint", "", "ECS_ENDPOINT", "ECS API endpoint override, skips regional endpoint resolution (ecs.<region>.aliyuncs.com)")
	reg.StringWithEnv(&alibabacloudcfg.VpcEndpoint, "vpc-endpoint", "", "VPC_ENDPOINT", "VPC API endpoint override, skips regional endpoint resolution (vpc.<region>.aliyuncs.com)")
	reg.BoolWithEnv(&alibabacloudcfg.IgnoreSSL, "ignore-ssl", false, "IGNORE_SSL", "Skip TLS certificate verification for ECS/VPC API endpoints (private cloud self-signed certs)")
	reg.StringWithEnv(&alibabacloudcfg.StsEndpoint, "sts-endpoint", "", "STS_ENDPOINT", "STS endpoint for RRSA AssumeRoleWithOIDC in private cloud, skips the default sts.aliyuncs.com resolution")
	reg.StringWithEnv(&alibabacloudcfg.ImageID, "imageid", "", "IMAGEID", "Pod VM image id", provider.Required())
	reg.StringWithEnv(&alibabacloudcfg.InstanceType, "instance-type", "ecs.g8i.xlarge", "PODVM_INSTANCE_TYPE", "Pod VM instance type")
	reg.StringWithEnv(&alibabacloudcfg.VswitchID, "vswitch-id", "", "VSWITCH_ID", "vSwitch ID to be used for the Pod VMs", provider.Required())
	reg.StringWithEnv(&alibabacloudcfg.KeyName, "keyname", "", "KEYNAME", "SSH Keypair name to be used with the Pod VM")
	reg.StringWithEnv(&alibabacloudcfg.Password, "password", "", "PASSWORD", "Login password (for root) to be used with the Pod VM - ignored when KEYNAME is set")

	reg.BoolWithEnv(&alibabacloudcfg.UsePublicIP, "use-public-ip", false, "USE_PUBLIC_IP", "Use Public IP for connecting to the kata-agent inside the Pod VM")
	reg.IntWithEnv(&alibabacloudcfg.SystemDiskSize, "system-disk-size", 40, "SYSTEM_DISK_SIZE", "System Disk size (in GiB) for the Pod VMs")
	reg.StringWithEnv(&alibabacloudcfg.SystemDiskCategory, "system-disk-category", "cloud_essd", "SYSTEM_DISK_CATEGORY", "System Disk category for the Pod VMs (e.g. cloud_essd, cloud_ssd, cloud_efficiency; must be available in the target zone)")
	reg.IntWithEnv(&alibabacloudcfg.InstanceReadyTimeout, "instance-ready-timeout", 180, "INSTANCE_READY_TIMEOUT", "Timeout (in seconds) to wait for the Pod VM instance to reach Running status before connecting to the agent forwarder")
	reg.StringWithEnv(&alibabacloudcfg.ConfidentialComputingMode, "confidential-computing-mode", "", "CONFIDENTIAL_COMPUTING_MODE", "Confidential computing mode for SecurityOptions (e.g. TDX on Intel, or the CSV value the console uses on Hygon); when set it is passed as-is; when empty and DISABLECVM=false falls back to TDX")
	reg.BoolWithEnv(&alibabacloudcfg.DisableCVM, "disable-cvm", false, "DISABLECVM", "Use non-CVMs for peer pods")

	// Flags without environment variable support (pass empty string for envVarName)
	reg.StringWithEnv(&alibabacloudcfg.VpcID, "vpc-id", "", "", "VPC ID to be used for the Pod VMs")

	// Custom flag types (comma-separated lists)
	reg.CustomTypeWithEnv(&alibabacloudcfg.SecurityGroupIDs, "security-group-ids", "cn-beijing", "SECURITY_GROUP_IDS", "Security Group Ids to be used for the Pod VM, comma separated")
	reg.CustomTypeWithEnv(&alibabacloudcfg.Tags, "tags", "", "TAGS", "Custom tags (key=value pairs) to be used for the Pod VMs, comma separated")
}

func (*Manager) LoadEnv() {
	// No longer needed - environment variables are handled in ParseCmd
}

func (*Manager) NewProvider() (provider.Provider, error) {
	return NewProvider(&alibabacloudcfg)
}

func (*Manager) GetConfig() (config *Config) {
	return &alibabacloudcfg
}
