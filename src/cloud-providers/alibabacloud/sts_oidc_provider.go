// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package alibabacloud

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/aliyun/credentials-go/credentials/providers"
)

// stsOIDCCredentialsProvider performs STS AssumeRoleWithOIDC (RRSA) against a
// custom private cloud STS endpoint. The built-in credentials-go OIDC provider
// only supports the public *.aliyuncs.com STS endpoints and always verifies
// TLS, which does not work in private cloud environments with internal STS
// gateways serving self-signed / SAN-less certificates.
type stsOIDCCredentialsProvider struct {
	stsEndpoint     string
	roleArn         string
	oidcProviderArn string
	oidcTokenFile   string
	insecureSSL     bool

	mu                  sync.Mutex
	expirationTimestamp int64
	session             *providers.Credentials
}

type assumeRoleWithOIDCResponse struct {
	Credentials *struct {
		AccessKeyId     *string `json:"AccessKeyId"`
		AccessKeySecret *string `json:"AccessKeySecret"`
		SecurityToken   *string `json:"SecurityToken"`
		Expiration      *string `json:"Expiration"`
	} `json:"Credentials"`
}

func (p *stsOIDCCredentialsProvider) GetProviderName() string {
	return "sts_oidc"
}

func (p *stsOIDCCredentialsProvider) GetCredentials() (*providers.Credentials, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	// reuse the session until 180s before expiration
	if p.session != nil && p.expirationTimestamp-time.Now().Unix() > 180 {
		return p.session, nil
	}

	token, err := os.ReadFile(p.oidcTokenFile)
	if err != nil {
		return nil, fmt.Errorf("read OIDC token file %s: %v", p.oidcTokenFile, err)
	}

	q := url.Values{}
	q.Set("Action", "AssumeRoleWithOIDC")
	q.Set("Version", "2015-04-01")
	q.Set("Format", "JSON")
	q.Set("Timestamp", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	form := url.Values{}
	form.Set("RoleArn", p.roleArn)
	form.Set("OIDCProviderArn", p.oidcProviderArn)
	form.Set("OIDCToken", string(token))
	form.Set("RoleSessionName", "caa-"+strconv.FormatInt(time.Now().Unix(), 10))
	form.Set("DurationSeconds", "3600")

	client := &http.Client{Timeout: 10 * time.Second}
	if p.insecureSSL {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}

	resp, err := client.PostForm("https://"+p.stsEndpoint+"?"+q.Encode(), form)
	if err != nil {
		return nil, fmt.Errorf("AssumeRoleWithOIDC against %s: %v", p.stsEndpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("AssumeRoleWithOIDC against %s: status %d", p.stsEndpoint, resp.StatusCode)
	}

	var data assumeRoleWithOIDCResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, fmt.Errorf("parse AssumeRoleWithOIDC response: %v", err)
	}
	if data.Credentials == nil || data.Credentials.AccessKeyId == nil ||
		data.Credentials.AccessKeySecret == nil || data.Credentials.SecurityToken == nil {
		return nil, fmt.Errorf("AssumeRoleWithOIDC against %s: no credentials in response", p.stsEndpoint)
	}

	expiration := time.Now().Add(time.Hour)
	if data.Credentials.Expiration != nil {
		if t, perr := time.Parse("2006-01-02T15:04:05Z", *data.Credentials.Expiration); perr == nil {
			expiration = t
		}
	}

	p.session = &providers.Credentials{
		AccessKeyId:     *data.Credentials.AccessKeyId,
		AccessKeySecret: *data.Credentials.AccessKeySecret,
		SecurityToken:   *data.Credentials.SecurityToken,
		ProviderName:    p.GetProviderName(),
	}
	p.expirationTimestamp = expiration.Unix()
	return p.session, nil
}
