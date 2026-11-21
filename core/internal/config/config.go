// Package config 定义 WgSense 的运行配置。
package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Config 是 WgSense 守护的运行配置。
type Config struct {
	// DesiredVPNEnabled records the user's intent to keep WireGuard up. It is
	// intentionally separate from the instantaneous tunnel state so transient
	// network failures do not clear the UI switch or stop reconnect attempts.
	DesiredVPNEnabled bool `json:"desired_vpn_enabled"`

	// DesiredGuardEnabled records the user's intent to keep trusted-network
	// automation enabled. The actual tunnel may still be disconnected on a
	// trusted network or while reconnecting.
	DesiredGuardEnabled bool `json:"desired_guard_enabled"`

	// AutoConnectUntrusted controls whether the daemon may connect WireGuard by
	// itself when the current network is outside trusted prefixes. Manual connect
	// is unaffected.
	AutoConnectUntrusted bool `json:"auto_connect_untrusted"`

	// TrustedNetworkPrefixes 已废弃：受信任改为看网关 MAC（gateway 包，存 gateway.json）。
	// 同网段的别人家会被误判成受信任。只在首次升级时读一次，用来提示确认当前网关。
	TrustedNetworkPrefixes []string `json:"trusted_network_prefixes"`

	// Deprecated compatibility fields. Keep accepting/emitting them so existing
	// UI builds and config files do not break while the product terminology moves
	// from "home/away" to "trusted/untrusted".
	AutoConnectAway     bool     `json:"auto_connect_away"`
	HomeNetworkPrefixes []string `json:"home_network_prefixes"`

	// IntervalSeconds 是巡检间隔秒数。
	IntervalSeconds int `json:"interval_seconds"`
	// AutoUpGraceSeconds 是自动拉起后的宽限期，防止抖动重连。
	AutoUpGraceSeconds int `json:"auto_up_grace_seconds"`
	// HealthCheckTarget 是假连接探测目标(必须走 WG 才能访问的地址)。
	HealthCheckTarget string `json:"health_check_target"`
	// HealthCheckIntervalSeconds 是假连接探测间隔(每 N 秒探一次)。
	HealthCheckIntervalSeconds int `json:"health_check_interval_seconds"`
}

// Default 返回默认配置。
func Default() Config {
	return Config{
		AutoConnectUntrusted:       false,
		TrustedNetworkPrefixes:     []string{},
		AutoConnectAway:            false,
		HomeNetworkPrefixes:        []string{},
		IntervalSeconds:            10,
		AutoUpGraceSeconds:         20,
		HealthCheckTarget:          "https://www.gstatic.com/generate_204",
		HealthCheckIntervalSeconds: 30,
	}
}

// LoadRuntime reads the daemon's persisted runtime configuration.
func LoadRuntime(path string) (Config, error) {
	cfg := Default()
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	cfg.Normalize()
	return cfg, nil
}

// SaveRuntime persists the daemon's runtime configuration atomically.
func SaveRuntime(path string, cfg Config) error {
	cfg.Normalize()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".settings-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write([]byte("\n")); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	return nil
}

func IsNotExist(err error) bool {
	return errors.Is(err, os.ErrNotExist)
}

// Normalize fills defaults and mirrors deprecated fields for compatibility.
func (c *Config) Normalize() {
	if c.IntervalSeconds <= 0 {
		c.IntervalSeconds = 10
	}
	if c.AutoUpGraceSeconds <= 0 {
		c.AutoUpGraceSeconds = 20
	}
	if c.HealthCheckTarget == "" {
		c.HealthCheckTarget = "https://www.gstatic.com/generate_204"
	}
	if c.HealthCheckIntervalSeconds <= 0 {
		c.HealthCheckIntervalSeconds = 30
	}
	if len(c.TrustedNetworkPrefixes) == 0 && len(c.HomeNetworkPrefixes) > 0 {
		c.TrustedNetworkPrefixes = append([]string(nil), c.HomeNetworkPrefixes...)
	}
	if len(c.HomeNetworkPrefixes) == 0 && len(c.TrustedNetworkPrefixes) > 0 {
		c.HomeNetworkPrefixes = append([]string(nil), c.TrustedNetworkPrefixes...)
	}
	if c.AutoConnectAway {
		c.AutoConnectUntrusted = true
	}
	c.AutoConnectAway = c.AutoConnectUntrusted
}
