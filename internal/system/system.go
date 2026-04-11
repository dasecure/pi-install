package system

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// Info holds system information.
type Info struct {
	Hostname      string
	Platform      string
	Architecture  string
	OS            string
	TailscaleIP   string
	IsPi          bool
	PiModel       string
	PiSerial      string
	LocalIP       string
}

// GetInfo collects system information.
func GetInfo() Info {
	info := Info{
		Platform:     runtime.GOOS,
		Architecture: runtime.GOARCH,
		OS:           runtime.GOOS,
	}
	info.Hostname, _ = os.Hostname()

	// Detect Raspberry Pi
	if data, err := os.ReadFile("/proc/device-tree/model"); err == nil {
		info.IsPi = true
		info.PiModel = strings.TrimRight(string(data), "\x00\n")
	}
	if data, err := os.ReadFile("/proc/device-tree/serial-number"); err == nil {
		info.PiSerial = strings.TrimRight(string(data), "\x00\n")
	}

	info.TailscaleIP = GetTailscaleIP()
	info.LocalIP = getLocalIP()

	return info
}

// GetTailscaleIP returns the Tailscale IPv4 address or empty string.
func GetTailscaleIP() string {
	out, err := exec.Command("tailscale", "ip", "-4").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func getLocalIP() string {
	// Use a UDP dial to determine outbound IP
	out, err := exec.Command("ip", "route", "get", "1.1.1.1").Output()
	if err != nil {
		return "unknown"
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "src") {
			parts := strings.Fields(line)
			for i, p := range parts {
				if p == "src" && i+1 < len(parts) {
					return parts[i+1]
				}
			}
		}
	}
	return "unknown"
}

// Stats holds live system metrics.
type Stats struct {
	CPUPercent    float64
	MemTotalMB    float64
	MemUsedMB     float64
	MemPercent    float64
	DiskTotalGB   float64
	DiskUsedGB    float64
	DiskPercent   float64
	UptimeSeconds float64
	Temperature   *float64
	LoadAvg       [3]float64
	TailscaleIP   string
}

// GetStats collects current system metrics.
func GetStats() Stats {
	s := Stats{}

	// CPU
	out, _ := exec.Command("sh", "-c", "grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf \"%.1f\", usage}'").Output()
	fmt.Sscanf(strings.TrimSpace(string(out)), "%f", &s.CPUPercent)

	// Memory from /proc/meminfo
	s.MemTotalMB, s.MemUsedMB = getMemInfo()

	// Disk
	s.DiskTotalGB, s.DiskUsedGB, s.DiskPercent = getDiskInfo()

	// Uptime
	s.UptimeSeconds = getUptime()

	// Temperature
	if temp := getCPUTemp(); temp > 0 {
		s.Temperature = &temp
	}

	// Load average
	if load := getLoadAvg(); load != nil {
		s.LoadAvg = *load
	}

	s.TailscaleIP = GetTailscaleIP()
	return s
}

func getMemInfo() (totalMB, usedMB float64) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	var memTotal, memAvailable, memFree, buffers, cached float64
	for _, line := range strings.Split(string(data), "\n") {
		var val float64
		if strings.HasPrefix(line, "MemTotal:") {
			fmt.Sscanf(strings.TrimPrefix(line, "MemTotal:"), "%f", &val)
			memTotal = val
		} else if strings.HasPrefix(line, "MemAvailable:") {
			fmt.Sscanf(strings.TrimPrefix(line, "MemAvailable:"), "%f", &val)
			memAvailable = val
		} else if strings.HasPrefix(line, "MemFree:") {
			fmt.Sscanf(strings.TrimPrefix(line, "MemFree:"), "%f", &val)
			memFree = val
		} else if strings.HasPrefix(line, "Buffers:") {
			fmt.Sscanf(strings.TrimPrefix(line, "Buffers:"), "%f", &val)
			buffers = val
		} else if strings.HasPrefix(line, "Cached:") {
			fmt.Sscanf(strings.TrimPrefix(line, "Cached:"), "%f", &val)
			cached = val
		}
	}
	totalMB = memTotal / 1024
	usedMB = (memTotal - memAvailable) / 1024
	_ = memFree + buffers + cached
	return
}

func getDiskInfo() (totalGB, usedGB, percent float64) {
	out, err := exec.Command("df", "-B1", "/").Output()
	if err != nil {
		return 0, 0, 0
	}
	lines := strings.Split(string(out), "\n")
	if len(lines) < 2 {
		return 0, 0, 0
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 6 {
		return 0, 0, 0
	}
	var total, used float64
	fmt.Sscanf(fields[1], "%f", &total)
	fmt.Sscanf(fields[2], "%f", &used)
	totalGB = total / 1073741824
	usedGB = used / 1073741824
	if total > 0 {
		percent = used / total * 100
	}
	return
}

func getUptime() float64 {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	var up float64
	fmt.Sscanf(strings.TrimSpace(string(data)), "%f", &up)
	return up
}

func getCPUTemp() float64 {
	data, err := os.ReadFile("/sys/class/thermal/thermal_zone0/temp")
	if err != nil {
		return 0
	}
	var millideg float64
	fmt.Sscanf(strings.TrimSpace(string(data)), "%f", &millideg)
	return millideg / 1000
}

func getLoadAvg() *[3]float64 {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return nil
	}
	var load [3]float64
	n, _ := fmt.Sscanf(strings.TrimSpace(string(data)), "%f %f %f", &load[0], &load[1], &load[2])
	if n == 3 {
		return &load
	}
	return nil
}

// TailscaleInstalled checks if tailscale binary is available.
func TailscaleInstalled() bool {
	_, err := exec.LookPath("tailscale")
	return err == nil
}

// InstallTailscale runs the Tailscale install script.
func InstallTailscale() error {
	return runCommand("sh", "-c", "curl -fsSL https://tailscale.com/install.sh | sh")
}

// ConnectTailscale brings Tailscale up with the given auth key and hostname.
func ConnectTailscale(authKey, hostname string) error {
	// Check if already connected
	if out, err := exec.Command("tailscale", "status").Output(); err == nil && len(out) > 0 {
		return nil // already connected
	}
	return runCommand("tailscale", "up", "--authkey="+authKey, "--ssh", "--hostname="+hostname)
}

// SetupVNC installs and configures TigerVNC on the system.
func SetupVNC(password string) error {
	// Install packages
	if err := runCommand("apt-get", "install", "-y", "tigervnc-standalone-server", "tigervnc-common", "xfce4", "xfce4-goodies", "dbus-x11"); err != nil {
		return fmt.Errorf("install VNC packages: %w", err)
	}

	// Set VNC password
	vncPassCmd := exec.Command("vncpasswd", "-f")
	vncPassCmd.Stdin = bytes.NewBufferString(password + "\n" + password + "\nn\n")
	out, err := vncPassCmd.Output()
	if err != nil {
		return fmt.Errorf("vncpasswd: %w", err)
	}

	// Write password file
	home := "/root"
	if u := os.Getenv("SUDO_USER"); u != "" {
		if h, err := exec.Command("getent", "passwd", u).Output(); err == nil {
			parts := strings.Split(strings.TrimSpace(string(h)), ":")
			if len(parts) >= 6 {
				home = parts[5]
			}
		}
	}
	vncDir := home + "/.vnc"
	os.MkdirAll(vncDir, 0700)
	if err := os.WriteFile(vncDir+"/passwd", out, 0600); err != nil {
		return fmt.Errorf("write vnc passwd: %w", err)
	}

	return nil
}

// FormatUptime formats seconds into a human-readable string.
func FormatUptime(seconds float64) string {
	days := int(seconds) / 86400
	hours := (int(seconds) % 86400) / 3600
	minutes := (int(seconds) % 3600) / 60
	parts := []string{}
	if days > 0 {
		parts = append(parts, fmt.Sprintf("%dd", days))
	}
	if hours > 0 {
		parts = append(parts, fmt.Sprintf("%dh", hours))
	}
	parts = append(parts, fmt.Sprintf("%dm", minutes))
	return strings.Join(parts, " ")
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
