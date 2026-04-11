package install

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/iotpush"
	"github.com/dasecure/pi-install/internal/system"
)

// Stage represents an installation stage.
type Stage struct {
	Name        string
	Emoji       string
	Fn          func(cfg *config.Config) error
	Skip        func(cfg *config.Config) bool
}

// RunHeadless executes the installer in non-interactive mode.
func RunHeadless(args []string, version string) {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	iotpushKey := fs.String("iotpush-key", "", "iotPush API key")
	iotpushTopic := fs.String("iotpush-topic", "", "iotPush topic name")
	tailscaleKey := fs.String("tailscale-key", "", "Tailscale auth key")
	hostname := fs.String("hostname", "zerotrust-pi", "Device hostname")
	apiToken := fs.String("api-token", "", "Custom API token (auto-generated if omitted)")
	noTailscale := fs.Bool("no-tailscale", false, "Skip Tailscale (VPS mode)")
	updateMode := fs.Bool("update", false, "Update agent files only")
	fs.Parse(args)

	if *hostname == "" {
		*hostname = "zerotrust-pi"
	}

	// Build config
	cfg := config.DefaultConfig()
	cfg.Agent.Version = version
	cfg.Agent.Hostname = *hostname

	if *apiToken != "" {
		cfg.Agent.APIToken = *apiToken
	} else {
		token, _ := generateToken()
		cfg.Agent.APIToken = token
	}

	cfg.IotPush.APIKey = *iotpushKey
	cfg.IotPush.Topic = *iotpushTopic
	cfg.IotPush.Enabled = *iotpushKey != "" && *iotpushTopic != ""
	cfg.Tailscale.Enabled = !*noTailscale
	cfg.Tailscale.AuthKey = *tailscaleKey

	if *updateMode {
		fmt.Println("📦 Update mode: refreshing agent files only...")
		if err := installAgentFiles(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Update failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✅ Update complete!")
		return
	}

	// Validate required args
	if cfg.Tailscale.Enabled && (cfg.IotPush.APIKey == "" || cfg.IotPush.Topic == "" || cfg.Tailscale.AuthKey == "") {
		fmt.Fprintf(os.Stderr, "Missing required arguments for Pi mode.\nUse --no-tailscale for VPS mode.\n")
		fs.Usage()
		os.Exit(1)
	}

	// Build stages
	stages := buildStages(cfg)

	fmt.Println()
	fmt.Println("╔════════════════════════════════════════════════════════╗")
	fmt.Println("║         Pi Zero-Trust Agent — Installer               ║")
	fmt.Println("╚════════════════════════════════════════════════════════╝")
	fmt.Println()

	total := len(stages)
	for i, stage := range stages {
		if stage.Skip != nil && stage.Skip(cfg) {
			continue
		}
		fmt.Printf("%s [%d/%d] %s...\n", stage.Emoji, i+1, total, stage.Name)
		if err := stage.Fn(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "❌ Stage '%s' failed: %v\n", stage.Name, err)
			os.Exit(1)
		}
		fmt.Printf("  ✓ %s complete\n", stage.Name)
	}

	fmt.Println()
	fmt.Println("✅ Installation complete!")
	fmt.Printf("   Hostname: %s\n", cfg.Agent.Hostname)
	if cfg.Tailscale.Enabled {
		fmt.Printf("   Tailscale IP: %s\n", system.GetTailscaleIP())
	}
	fmt.Printf("   API: http://localhost:%d/health\n", cfg.Agent.Port)
	fmt.Printf("   Token: %s\n", cfg.Agent.APIToken)
}

func buildStages(cfg *config.Config) []Stage {
	return []Stage{
		{
			Name:  "Dependencies",
			Emoji: "📦",
			Fn:    installDeps,
		},
		{
			Name:  "Network",
			Emoji: "🌐",
			Fn:    configureNetwork,
		},
		{
			Name:  "iotPush Validation",
			Emoji: "📡",
			Fn:    validateIotPush,
			Skip: func(c *config.Config) bool {
				return !c.IotPush.Enabled
			},
		},
		{
			Name:  "Tailscale",
			Emoji: "🔒",
			Fn:    installTailscale,
			Skip: func(c *config.Config) bool {
				return !c.Tailscale.Enabled
			},
		},
		{
			Name:  "Config",
			Emoji: "⚙️",
			Fn:    writeConfig,
		},
		{
			Name:  "Agent",
			Emoji: "🤖",
			Fn:    installAgentFiles,
		},
		{
			Name:  "Service",
			Emoji: "🔧",
			Fn:    installService,
		},
	}
}

func installDeps(cfg *config.Config) error {
	// Check if running on Debian/Ubuntu
	if _, err := os.Stat("/usr/bin/apt-get"); err == nil {
		cmd := exec.Command("apt-get", "install", "-y", "curl", "python3", "python3-pip", "python3-venv")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		_ = cmd.Run() // best effort
	}
	return nil
}

func configureNetwork(cfg *config.Config) error {
	// Set hostname
	if cfg.Agent.Hostname != "" {
		_ = exec.Command("hostnamectl", "set-hostname", cfg.Agent.Hostname).Run()
	}
	return nil
}

func validateIotPush(cfg *config.Config) error {
	client := iotpush.NewClient(cfg.IotPush.APIKey, cfg.IotPush.Topic)
	if err := client.Validate(); err != nil {
		return fmt.Errorf("iotPush validation failed: %w", err)
	}
	return nil
}

func installTailscale(cfg *config.Config) error {
	if !system.TailscaleInstalled() {
		fmt.Println("  Installing Tailscale...")
		if err := system.InstallTailscale(); err != nil {
			return fmt.Errorf("install tailscale: %w", err)
		}
	} else {
		fmt.Println("  Tailscale already installed")
	}

	fmt.Println("  Connecting to Tailscale...")
	if err := system.ConnectTailscale(cfg.Tailscale.AuthKey, cfg.Agent.Hostname); err != nil {
		// Log warning but don't fail — Tailscale might need manual auth
		fmt.Fprintf(os.Stderr, "  ⚠ Tailscale connect: %v\n", err)
	}

	tsIP := system.GetTailscaleIP()
	if tsIP != "" {
		fmt.Printf("  Tailscale IP: %s\n", tsIP)
	}

	// Send install notification
	client := iotpush.NewClient(cfg.IotPush.APIKey, cfg.IotPush.Topic)
	_ = client.Push("🔒 Agent Installing", fmt.Sprintf("Installing on %s (%s)", cfg.Agent.Hostname, tsIP))

	return nil
}

func writeConfig(cfg *config.Config) error {
	return cfg.Save(config.DefaultConfigPath)
}

func installAgentFiles(cfg *config.Config) error {
	dirs := []string{
		"/opt/pi-utility/pi-service",
		cfg.Agent.LogPath,
		cfg.Agent.PagesPath,
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("create dir %s: %w", dir, err)
		}
	}

	// Copy the current binary as the agent
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("get executable path: %w", err)
	}
	data, err := os.ReadFile(exe)
	if err != nil {
		return fmt.Errorf("read binary: %w", err)
	}
	if err := os.WriteFile("/opt/pi-utility/pi-service/pi-agent", data, 0755); err != nil {
		return fmt.Errorf("write agent binary: %w", err)
	}

	// Create pi-notify helper script
	notifyScript := fmt.Sprintf(`#!/bin/sh
curl -s -d "$1" \
  -H "Authorization: Bearer %s" \
  https://www.iotpush.com/api/push/%s
`, cfg.IotPush.APIKey, cfg.IotPush.Topic)
	if err := os.WriteFile("/usr/local/bin/pi-notify", []byte(notifyScript), 0755); err != nil {
		return fmt.Errorf("write pi-notify: %w", err)
	}

	return nil
}

func installService(cfg *config.Config) error {
	binaryPath := "/opt/pi-utility/pi-service/pi-agent"
	configPath := config.DefaultConfigPath

	serviceUnit := fmt.Sprintf(`[Unit]
Description=Pi Zero-Trust Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s serve --config %s
WorkingDirectory=/opt/pi-utility/pi-service
Restart=always
RestartSec=5
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
`, binaryPath, configPath)

	if err := os.WriteFile("/etc/systemd/system/pi-monitor.service", []byte(serviceUnit), 0644); err != nil {
		return fmt.Errorf("write service file: %w", err)
	}

	// Reload and enable
	for _, cmd := range [][]string{
		{"systemctl", "daemon-reload"},
		{"systemctl", "enable", "pi-monitor"},
		{"systemctl", "restart", "pi-monitor"},
	} {
		c := exec.Command(cmd[0], cmd[1:]...)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "  ⚠ %s: %v\n", strings.Join(cmd, " "), err)
		}
	}

	return nil
}

func generateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
