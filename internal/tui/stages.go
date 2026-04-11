package tui

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/system"
)

// Stage represents an installation stage.
type Stage struct {
	Name   string
	Emoji  string
	Fn     func(log func(string)) error
	Skip   func() bool
}

// BuildStages returns the installation stages for the given config.
func BuildStages(cfg *config.Config) []Stage {
	return []Stage{
		{
			Name:  "Config",
			Emoji: "⚙️",
			Fn: func(log func(string)) error {
				if cfg.Agent.APIToken == "" {
					return fmt.Errorf("API token is required")
				}
				if err := cfg.Save(config.DefaultConfigPath); err != nil {
					return fmt.Errorf("save config: %w", err)
				}
				log("  ✓ Config written to " + config.DefaultConfigPath)
				return nil
			},
		},
		{
			Name:  "Directories",
			Emoji: "📁",
			Fn: func(log func(string)) error {
				dirs := []string{
					"/opt/pi-utility/pi-service",
					cfg.Agent.LogPath,
					cfg.Agent.PagesPath,
				}
				for _, dir := range dirs {
					if err := os.MkdirAll(dir, 0755); err != nil {
						return fmt.Errorf("create %s: %w", dir, err)
					}
				}
				log("  ✓ Directories created")
				return nil
			},
		},
		{
			Name:  "Hostname",
			Emoji: "🏷️",
			Fn: func(log func(string)) error {
				if cfg.Agent.Hostname == "" {
					hostname, _ := os.Hostname()
					cfg.Agent.Hostname = hostname
				}
				if _, err := exec.LookPath("hostnamectl"); err == nil {
					_ = exec.Command("hostnamectl", "set-hostname", cfg.Agent.Hostname).Run()
					log(fmt.Sprintf("  ✓ Hostname set to %s", cfg.Agent.Hostname))
				} else {
					log("  ⚠ hostnamectl not found, skipping hostname set")
				}
				return nil
			},
		},
		{
			Name:  "Tailscale",
			Emoji: "🔒",
			Skip: func() bool { return !cfg.Tailscale.Enabled },
			Fn: func(log func(string)) error {
				if !system.TailscaleInstalled() {
					log("  Installing Tailscale...")
					if err := system.InstallTailscale(); err != nil {
						return fmt.Errorf("install tailscale: %w", err)
					}
					log("  ✓ Tailscale installed")
				} else {
					log("  ✓ Tailscale already installed")
				}

				if cfg.Tailscale.AuthKey != "" {
					log("  Connecting to Tailscale...")
					if err := system.ConnectTailscale(cfg.Tailscale.AuthKey, cfg.Agent.Hostname); err != nil {
						log(fmt.Sprintf("  ⚠ Tailscale connect: %v", err))
					} else {
						tsIP := system.GetTailscaleIP()
						log(fmt.Sprintf("  ✓ Tailscale connected: %s", tsIP))
					}
				}
				return nil
			},
		},
		{
			Name:  "Agent Binary",
			Emoji: "🤖",
			Fn: func(log func(string)) error {
				// Find the current binary
				exe, err := os.Executable()
				if err != nil {
					return fmt.Errorf("get executable: %w", err)
				}
				// Resolve symlinks
				if resolved, err := filepath.EvalSymlinks(exe); err == nil {
					exe = resolved
				}
				dest := "/opt/pi-utility/pi-service/pi-agent"
				data, err := os.ReadFile(exe)
				if err != nil {
					return fmt.Errorf("read binary: %w", err)
				}
				if err := os.WriteFile(dest, data, 0755); err != nil {
					return fmt.Errorf("write agent binary: %w", err)
				}
				log("  ✓ Agent binary installed")
				return nil
			},
		},
		{
			Name:  "Notify Helper",
			Emoji: "🔔",
			Skip: func() bool { return !cfg.IotPush.Enabled || cfg.IotPush.APIKey == "" },
			Fn: func(log func(string)) error {
				script := fmt.Sprintf(`#!/bin/sh
curl -s -d "$1" \
  -H "Authorization: Bearer %s" \
  https://www.iotpush.com/api/push/%s
`, cfg.IotPush.APIKey, cfg.IotPush.Topic)
				if err := os.WriteFile("/usr/local/bin/pi-notify", []byte(script), 0755); err != nil {
					return fmt.Errorf("write pi-notify: %w", err)
				}
				log("  ✓ /usr/local/bin/pi-notify created")
				return nil
			},
		},
		{
			Name:  "Service",
			Emoji: "🔧",
			Fn: func(log func(string)) error {
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
					return fmt.Errorf("write service: %w", err)
				}
				log("  ✓ Service file written")

				commands := [][]string{
					{"systemctl", "daemon-reload"},
					{"systemctl", "enable", "pi-monitor"},
					{"systemctl", "restart", "pi-monitor"},
				}
				for _, cmd := range commands {
					if err := exec.Command(cmd[0], cmd[1:]...).Run(); err != nil {
						log(fmt.Sprintf("  ⚠ %s: %v", strings.Join(cmd, " "), err))
					}
				}
				log("  ✓ Service enabled and started")
				return nil
			},
		},
		{
			Name:  "Firewall",
			Emoji: "🛡️",
			Skip: func() bool {
				// Skip if ufw not installed or on non-Linux
				_, err := exec.LookPath("ufw")
				return err != nil || runtime.GOOS != "linux"
			},
			Fn: func(log func(string)) error {
				// Allow port 8080
				_ = exec.Command("ufw", "allow", "8080/tcp").Run()
				log("  ✓ Port 8080 allowed in firewall")
				return nil
			},
		},
	}
}
