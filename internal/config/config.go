package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

const DefaultConfigPath = "/etc/pi-zero-trust/config.yaml"

// Config is the single YAML configuration file for the agent.
type Config struct {
	Agent    AgentConfig    `yaml:"agent"`
	IotPush  IotPushConfig  `yaml:"iotpush"`
	Tailscale TailscaleConfig `yaml:"tailscale"`
	VNC      VNCConfig      `yaml:"vnc"`
}

type AgentConfig struct {
	Version    string `yaml:"version"`
	Hostname   string `yaml:"hostname"`
	APIToken   string `yaml:"api_token"`
	Port       int    `yaml:"port"`
	TailscaleOnly bool `yaml:"tailscale_only"`
	LogPath    string `yaml:"log_path"`
	PagesPath  string `yaml:"pages_path"`
}

type IotPushConfig struct {
	APIKey  string `yaml:"api_key"`
	Topic   string `yaml:"topic"`
	Enabled bool   `yaml:"enabled"`
}

type TailscaleConfig struct {
	AuthKey string `yaml:"auth_key"`
	Enabled bool   `yaml:"enabled"`
}

type VNCConfig struct {
	Password string `yaml:"password"`
	Enabled  bool   `yaml:"enabled"`
}

// DefaultConfig returns a config with sensible defaults.
func DefaultConfig() *Config {
	return &Config{
		Agent: AgentConfig{
			Port:         8080,
			TailscaleOnly: true,
			LogPath:      "/var/log/pi-monitor",
			PagesPath:    "/var/www/pi-pages",
		},
		IotPush: IotPushConfig{
			Enabled: true,
		},
		Tailscale: TailscaleConfig{
			Enabled: true,
		},
		VNC: VNCConfig{
			Enabled: false,
		},
	}
}

// Load reads config from the given path.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	cfg := DefaultConfig()
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

// Save writes config to the given path.
func (c *Config) Save(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := yaml.Marshal(c)
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

// LoadOrDie loads config or exits with an error.
func LoadOrDie(path string) *Config {
	cfg, err := Load(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config from %s: %v\n", path, err)
		os.Exit(1)
	}
	return cfg
}
