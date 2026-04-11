package main

import (
	"fmt"
	"os"

	"github.com/dasecure/pi-install/internal/agent"
	"github.com/dasecure/pi-install/internal/install"
	"github.com/dasecure/pi-install/internal/tui"
)

var version = "3.1.0"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "serve":
			agent.Serve(version)
		case "install":
			install.RunHeadless(os.Args[2:], version)
		case "version":
			fmt.Printf("pi-agent %s\n", version)
		case "help":
			printHelp()
		default:
			fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
			printHelp()
			os.Exit(1)
		}
		return
	}

	// No subcommand: launch interactive TUI
	tui.Run(version)
}

func printHelp() {
	fmt.Println(`pi-agent — Pi Zero-Trust Agent

Usage:
  pi-agent              Interactive TUI setup
  pi-agent serve        Start the monitoring agent (HTTP API)
  pi-agent install      Headless install (for curl|bash)
  pi-agent version      Print version
  pi-agent help         Show this help

Install flags:
  --iotpush-key KEY       iotPush API key
  --iotpush-topic TOPIC   iotPush topic name
  --tailscale-key KEY     Tailscale auth key
  --hostname NAME         Device hostname (default: zerotrust-pi)
  --api-token TOKEN       Custom API token (auto-generated if omitted)
  --no-tailscale          Skip Tailscale setup (VPS mode)
  --watchdog              Enable hardware watchdog
  --update                Update agent files only`)
}
