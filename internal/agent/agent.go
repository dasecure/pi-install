package agent

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/iotpush"
	"github.com/dasecure/pi-install/internal/system"
)

var (
	cfg       *config.Config
	iotClient *iotpush.Client
	agentVersion string
)

// Serve starts the monitoring agent HTTP server.
func Serve(version string) {
	agentVersion = version
	configPath := config.DefaultConfigPath
	for i, arg := range os.Args {
		if arg == "--config" && i+1 < len(os.Args) {
			configPath = os.Args[i+1]
		}
	}

	var err error
	cfg, err = config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", err)
		os.Exit(1)
	}
	cfg.Agent.Version = version

	if cfg.IotPush.Enabled && cfg.IotPush.APIKey != "" {
		iotClient = iotpush.NewClient(cfg.IotPush.APIKey, cfg.IotPush.Topic)
	}

	// Notify online
	if iotClient != nil {
		info := system.GetInfo()
		_ = iotClient.Push(fmt.Sprintf("🟢 %s Online", info.Hostname),
			fmt.Sprintf("%s is online at %s", info.Hostname, info.TailscaleIP))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", withAuth(rootHandler))
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/stats", withAuth(statsHandler))
	mux.HandleFunc("/system", withAuth(systemHandler))
	mux.HandleFunc("/logs/", withAuth(logsHandler))
	mux.HandleFunc("/settings", withAuth(settingsHandler))
	mux.HandleFunc("/notify", withAuth(notifyHandler))
	mux.HandleFunc("/reboot", withAuth(rebootHandler))
	mux.HandleFunc("/shutdown", withAuth(shutdownHandler))
	mux.HandleFunc("/check-update", withAuth(checkUpdateHandler))
	mux.HandleFunc("/update", withAuth(updateHandler))
	mux.HandleFunc("/version", versionHandler)

	addr := fmt.Sprintf(":%d", cfg.Agent.Port)
	fmt.Printf("🤖 Pi Zero-Trust Agent v%s starting on %s\n", version, addr)

	defer func() {
		if iotClient != nil {
			info := system.GetInfo()
			_ = iotClient.Push(fmt.Sprintf("🔴 %s Offline", info.Hostname),
				fmt.Sprintf("%s has gone offline", info.Hostname))
		}
	}()

	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}

func withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || r.URL.Path == "/version" {
			next(w, r)
			return
		}

		// Trust Tailscale IPs
		ip := strings.Split(r.RemoteAddr, ":")[0]
		if strings.HasPrefix(ip, "100.") {
			next(w, r)
			return
		}

		token := r.Header.Get("X-API-Token")
		if token == "" {
			auth := r.Header.Get("Authorization")
			token = strings.TrimPrefix(auth, "Bearer ")
		}

		if cfg.Agent.APIToken == "" {
			next(w, r)
			return
		}

		if token != cfg.Agent.APIToken {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func jsonResponse(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	jsonResponse(w, map[string]interface{}{
		"status":   "healthy",
		"hostname": hostname,
		"version":  agentVersion,
		"uptime":   system.FormatUptime(system.GetStats().UptimeSeconds),
	})
}

func versionHandler(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, map[string]interface{}{
		"version":      agentVersion,
		"latest":       "", // populated by /check-update
		"platform":     runtime.GOOS + "/" + runtime.GOARCH,
		"update_available": false,
	})
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	hostname, _ := os.Hostname()
	jsonResponse(w, map[string]interface{}{
		"service":   "Pi Zero-Trust Agent",
		"version":   agentVersion,
		"hostname":  hostname,
		"endpoints": []string{"/health", "/version", "/stats", "/system", "/logs", "/settings", "/notify", "/check-update", "/update", "/reboot", "/shutdown"},
	})
}

func statsHandler(w http.ResponseWriter, r *http.Request) {
	stats := system.GetStats()
	hostname, _ := os.Hostname()
	jsonResponse(w, map[string]interface{}{
		"hostname":        hostname,
		"uptime_seconds":  stats.UptimeSeconds,
		"uptime_human":    system.FormatUptime(stats.UptimeSeconds),
		"cpu_percent":     stats.CPUPercent,
		"memory_total_mb": stats.MemTotalMB,
		"memory_used_mb":  stats.MemUsedMB,
		"memory_percent":  stats.MemPercent,
		"disk_total_gb":   stats.DiskTotalGB,
		"disk_used_gb":    stats.DiskUsedGB,
		"disk_percent":    stats.DiskPercent,
		"temperature_c":   stats.Temperature,
		"load_average":    stats.LoadAvg,
		"tailscale_ip":    stats.TailscaleIP,
		"version":         agentVersion,
		"timestamp":       time.Now().Format(time.RFC3339),
	})
}

func systemHandler(w http.ResponseWriter, r *http.Request) {
	info := system.GetInfo()
	var tsVersion string
	if out, err := exec.Command("tailscale", "version").Output(); err == nil {
		tsVersion = strings.Split(strings.TrimSpace(string(out)), "\n")[0]
	}
	jsonResponse(w, map[string]interface{}{
		"hostname":          info.Hostname,
		"platform":          info.Platform,
		"architecture":      info.Architecture,
		"tailscale_version": tsVersion,
		"pi_model":          info.PiModel,
		"pi_serial":         info.PiSerial,
		"agent_version":     agentVersion,
	})
}

func logsHandler(w http.ResponseWriter, r *http.Request) {
	logType := strings.TrimPrefix(r.URL.Path, "/logs/")
	allowed := map[string][]string{
		"system":     {"journalctl", "-n", "100", "--no-pager"},
		"auth":       {"journalctl", "-n", "100", "--no-pager", "-u", "ssh"},
		"pi-monitor": {"journalctl", "-n", "100", "--no-pager", "-u", "pi-monitor"},
		"tailscale":  {"journalctl", "-n", "100", "--no-pager", "-u", "tailscaled"},
	}
	cmdArgs, ok := allowed[logType]
	if !ok {
		http.Error(w, `{"error":"unknown log type"}`, http.StatusBadRequest)
		return
	}
	out, err := exec.Command(cmdArgs[0], cmdArgs[1:]...).Output()
	if err != nil {
		http.Error(w, `{"error":"failed to fetch logs"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func settingsHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		jsonResponse(w, cfg)
	case http.MethodPut:
		var newCfg config.Config
		if err := json.NewDecoder(r.Body).Decode(&newCfg); err != nil {
			http.Error(w, `{"error":"invalid JSON"}`, http.StatusBadRequest)
			return
		}
		if newCfg.IotPush.APIKey != cfg.IotPush.APIKey || newCfg.IotPush.Topic != cfg.IotPush.Topic {
			iotClient = iotpush.NewClient(newCfg.IotPush.APIKey, newCfg.IotPush.Topic)
		}
		cfg = &newCfg
		_ = cfg.Save(config.DefaultConfigPath)
		jsonResponse(w, map[string]string{"status": "saved"})
	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

func notifyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Title   string `json:"title"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid JSON"}`, http.StatusBadRequest)
		return
	}
	if iotClient == nil {
		http.Error(w, `{"error":"iotPush not configured"}`, http.StatusServiceUnavailable)
		return
	}
	if err := iotClient.Push(req.Title, req.Message); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"%v"}`, err), http.StatusInternalServerError)
		return
	}
	jsonResponse(w, map[string]string{"status": "sent"})
}

func rebootHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	if iotClient != nil {
		info := system.GetInfo()
		_ = iotClient.Push(fmt.Sprintf("🔄 %s Rebooting", info.Hostname), fmt.Sprintf("%s is rebooting", info.Hostname))
	}
	jsonResponse(w, map[string]string{"status": "rebooting"})
	go func() {
		time.Sleep(1 * time.Second)
		_ = exec.Command("reboot").Run()
	}()
}

func shutdownHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	if iotClient != nil {
		info := system.GetInfo()
		_ = iotClient.Push(fmt.Sprintf("⏹️ %s Shutting Down", info.Hostname), fmt.Sprintf("%s is shutting down", info.Hostname))
	}
	jsonResponse(w, map[string]string{"status": "shutting down"})
	go func() {
		time.Sleep(1 * time.Second)
		_ = exec.Command("shutdown", "-h", "now").Run()
	}()
}

// ─── Update System ──────────────────────────────────────────

const repoOwner = "dasecure"
const repoName = "pi-install"

// githubRelease represents a GitHub release.
type githubRelease struct {
	TagName string `json:"tag_name"`
	Name    string `json:"name"`
	Body    string `json:"body"`
	HTMLURL string `json:"html_url"`
	Assets  []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Size               int64  `json:"size"`
	} `json:"assets"`
}

// checkUpdateHandler checks GitHub for the latest release.
func checkUpdateHandler(w http.ResponseWriter, r *http.Request) {
	release, err := fetchLatestRelease()
	if err != nil {
		jsonResponse(w, map[string]interface{}{
			"update_available": false,
			"current_version":  agentVersion,
			"error":            err.Error(),
		})
		return
	}

	latest := strings.TrimPrefix(release.TagName, "v")
	updateAvailable := latest != agentVersion && latest != ""

	jsonResponse(w, map[string]interface{}{
		"update_available":  updateAvailable,
		"current_version":   agentVersion,
		"latest_version":    latest,
		"release_name":      release.Name,
		"release_notes":     release.Body,
		"release_url":       release.HTMLURL,
		"platform":          runtime.GOOS + "/" + runtime.GOARCH,
	})
}

// updateHandler downloads the latest binary and restarts the agent.
func updateHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	// Find the right asset for this platform
	platform := runtime.GOOS
	arch := runtime.GOARCH
	assetPattern := fmt.Sprintf("pi-agent-%s-%s", platform, arch)
	if platform == "windows" {
		assetPattern += ".exe"
	}

	release, err := fetchLatestRelease()
	if err != nil {
		jsonResponse(w, map[string]interface{}{
			"success": false,
			"error":   fmt.Sprintf("fetch release: %v", err),
		})
		return
	}

	latest := strings.TrimPrefix(release.TagName, "v")
	if latest == agentVersion {
		jsonResponse(w, map[string]interface{}{
			"success": true,
			"message": "Already up to date",
			"version": agentVersion,
		})
		return
	}

	// Find matching asset
	var downloadURL string
	for _, asset := range release.Assets {
		if strings.Contains(asset.Name, assetPattern) {
			downloadURL = asset.BrowserDownloadURL
			break
		}
	}

	if downloadURL == "" {
		jsonResponse(w, map[string]interface{}{
			"success": false,
			"error":   fmt.Sprintf("no binary found for %s (pattern: %s)", platform+"/"+arch, assetPattern),
			"hint":    "Build and upload from source: make all && gh release upload",
		})
		return
	}

	// Notify
	if iotClient != nil {
		info := system.GetInfo()
		_ = iotClient.Push(
			fmt.Sprintf("⬆️ %s Updating", info.Hostname),
			fmt.Sprintf("Updating from v%s to v%s", agentVersion, latest),
		)
	}

	// Send response before restarting
	jsonResponse(w, map[string]interface{}{
		"success":    true,
		"message":    fmt.Sprintf("Updating to v%s, restarting...", latest),
		"from":       agentVersion,
		"to":         latest,
	})

	// Flush response
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	// Download and replace
	go func() {
		time.Sleep(500 * time.Millisecond)
		if err := selfUpdate(downloadURL); err != nil {
			fmt.Fprintf(os.Stderr, "Self-update failed: %v\n", err)
			if iotClient != nil {
				_ = iotClient.Push("❌ Update Failed", err.Error())
			}
			return
		}

		// Restart the service
		_ = exec.Command("systemctl", "restart", "pi-monitor").Run()
	}()
}

// fetchLatestRelease queries GitHub API for the latest release.
func fetchLatestRelease() (*githubRelease, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/latest", repoOwner, repoName)
	client := &http.Client{Timeout: 15 * time.Second}

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "pi-agent")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("github api: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("github api returned %d", resp.StatusCode)
	}

	var release githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &release, nil
}

// selfUpdate downloads a new binary and replaces the current one.
func selfUpdate(downloadURL string) error {
	// Get current executable path
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("get exe path: %w", err)
	}
	exe, err = resolveSymlink(exe)
	if err != nil {
		return fmt.Errorf("resolve symlink: %w", err)
	}

	// Download to temp file
	resp, err := http.Get(downloadURL)
	if err != nil {
		return fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("download returned %d", resp.StatusCode)
	}

	tmpFile := exe + ".new"
	f, err := os.OpenFile(tmpFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}

	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(tmpFile)
		return fmt.Errorf("write binary: %w", err)
	}
	f.Close()

	// Backup current binary
	backup := exe + ".bak"
	os.Remove(backup)
	if err := os.Rename(exe, backup); err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("backup old binary: %w", err)
	}

	// Move new binary into place
	if err := os.Rename(tmpFile, exe); err != nil {
		// Rollback
		os.Rename(backup, exe)
		return fmt.Errorf("replace binary: %w", err)
	}

	os.Remove(backup)
	fmt.Printf("✅ Updated binary: %s\n", exe)
	return nil
}

func resolveSymlink(path string) (string, error) {
	for i := 0; i < 5; i++ {
		info, err := os.Lstat(path)
		if err != nil {
			return path, nil
		}
		if info.Mode()&os.ModeSymlink == 0 {
			return path, nil
		}
		target, err := os.Readlink(path)
		if err != nil {
			return path, nil
		}
		if !strings.HasPrefix(target, "/") {
			target = filepath.Dir(path) + "/" + target
		}
		path = target
	}
	return path, nil
}
