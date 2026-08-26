// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package alibabacloud

import (
	ecs "github.com/alibabacloud-go/ecs-20140526/v4/client"
	util "github.com/alibabacloud-go/tea-utils/v2/service"
	"github.com/alibabacloud-go/tea/tea"
	vpc "github.com/alibabacloud-go/vpc-20160428/v6/client"
)

// insecureRuntime returns runtime options that skip TLS certificate
// verification, needed for private cloud endpoints serving HTTPS with
// self-signed / SAN-less certificates.
func insecureRuntime() *util.RuntimeOptions {
	return &util.RuntimeOptions{IgnoreSSL: tea.Bool(true)}
}

// insecureEcsClient wraps the real ECS client and routes every call
// through the *WithOptions variant with IgnoreSSL enabled.
type insecureEcsClient struct {
	inner *ecs.Client
}

func (c insecureEcsClient) RunInstances(
	params *ecs.RunInstancesRequest) (*ecs.RunInstancesResponse, error) {
	return c.inner.RunInstancesWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) DeleteInstance(
	params *ecs.DeleteInstanceRequest) (*ecs.DeleteInstanceResponse, error) {
	return c.inner.DeleteInstanceWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) DescribeInstanceTypes(
	params *ecs.DescribeInstanceTypesRequest) (*ecs.DescribeInstanceTypesResponse, error) {
	return c.inner.DescribeInstanceTypesWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) DescribeInstanceAttribute(
	params *ecs.DescribeInstanceAttributeRequest) (*ecs.DescribeInstanceAttributeResponse, error) {
	return c.inner.DescribeInstanceAttributeWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) CreateNetworkInterface(
	params *ecs.CreateNetworkInterfaceRequest) (*ecs.CreateNetworkInterfaceResponse, error) {
	return c.inner.CreateNetworkInterfaceWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) DeleteNetworkInterface(
	params *ecs.DeleteNetworkInterfaceRequest) (*ecs.DeleteNetworkInterfaceResponse, error) {
	return c.inner.DeleteNetworkInterfaceWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) AttachNetworkInterface(
	params *ecs.AttachNetworkInterfaceRequest) (*ecs.AttachNetworkInterfaceResponse, error) {
	return c.inner.AttachNetworkInterfaceWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) ModifyNetworkInterfaceAttribute(
	params *ecs.ModifyNetworkInterfaceAttributeRequest) (*ecs.ModifyNetworkInterfaceAttributeResponse, error) {
	return c.inner.ModifyNetworkInterfaceAttributeWithOptions(params, insecureRuntime())
}

func (c insecureEcsClient) DescribeNetworkInterfaceAttribute(
	params *ecs.DescribeNetworkInterfaceAttributeRequest) (*ecs.DescribeNetworkInterfaceAttributeResponse, error) {
	return c.inner.DescribeNetworkInterfaceAttributeWithOptions(params, insecureRuntime())
}

// insecureVpcClient wraps the real VPC client and routes every call
// through the *WithOptions variant with IgnoreSSL enabled.
type insecureVpcClient struct {
	inner *vpc.Client
}

func (c insecureVpcClient) DescribeVSwitchAttributes(
	params *vpc.DescribeVSwitchAttributesRequest) (*vpc.DescribeVSwitchAttributesResponse, error) {
	return c.inner.DescribeVSwitchAttributesWithOptions(params, insecureRuntime())
}

func (c insecureVpcClient) AllocateEipAddress(
	params *vpc.AllocateEipAddressRequest) (*vpc.AllocateEipAddressResponse, error) {
	return c.inner.AllocateEipAddressWithOptions(params, insecureRuntime())
}

func (c insecureVpcClient) ReleaseEipAddress(
	params *vpc.ReleaseEipAddressRequest) (*vpc.ReleaseEipAddressResponse, error) {
	return c.inner.ReleaseEipAddressWithOptions(params, insecureRuntime())
}

func (c insecureVpcClient) AssociateEipAddress(
	params *vpc.AssociateEipAddressRequest) (*vpc.AssociateEipAddressResponse, error) {
	return c.inner.AssociateEipAddressWithOptions(params, insecureRuntime())
}

func (c insecureVpcClient) UnassociateEipAddress(
	params *vpc.UnassociateEipAddressRequest) (*vpc.UnassociateEipAddressResponse, error) {
	return c.inner.UnassociateEipAddressWithOptions(params, insecureRuntime())
}

func (c insecureVpcClient) DescribeEipAddresses(
	params *vpc.DescribeEipAddressesRequest) (*vpc.DescribeEipAddressesResponse, error) {
	return c.inner.DescribeEipAddressesWithOptions(params, insecureRuntime())
}
