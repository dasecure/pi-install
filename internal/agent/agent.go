package agent

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/iotpush"
	"github.com/dasecure/pi-install/internal/system"
)

var cfg *config.Config
var iotClient *iotpush.Client

// Serve starts the monitoring agent HTTP server.
func Serve(version string) {
	configPath := config.DefaultConfigPath
	// Check for --config flag
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

	addr := fmt.Sprintf(":%d", cfg.Agent.Port)
	fmt.Printf("🤖 Pi Zero-Trust Agent v%s starting on %s\n", version, addr)

	// Notify shutdown
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
		// Allow health without auth
		if r.URL.Path == "/health" {
			next(w, r)
			return
		}

		// Trust Tailscale IPs
		ip := strings.Split(r.RemoteAddr, ":")[0]
		if strings.HasPrefix(ip, "100.") {
			next(w, r)
			return
		}

		// Check token
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
		"version":  cfg.Agent.Version,
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
		"version":   cfg.Agent.Version,
		"hostname":  hostname,
		"endpoints": []string{"/health", "/stats", "/system", "/logs", "/settings", "/notify"},
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
		// Update iotpush client if keys changed
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
	jsonResponse(w, map[string]string{"status": "shutting down"})
	go func() {
		time.Sleep(1 * time.Second)
		_ = exec.Command("shutdown", "-h", "now").Run()
	}()
}
