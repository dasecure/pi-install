package tui

import (
	"crypto/rand"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/skip2/go-qrcode"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/iotpush"
	"github.com/dasecure/pi-install/internal/system"
)

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("36")).
			MarginBottom(1)

	boxStyle = lipgloss.NewStyle().
			Border(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.Color("36")).
			Padding(1, 2).
			Margin(1, 2)

	successBoxStyle = lipgloss.NewStyle().
				Border(lipgloss.DoubleBorder()).
				BorderForeground(lipgloss.Color("76")).
				Padding(1, 2).
				Margin(1, 2)

	dimStyle = lipgloss.NewStyle().Faint(true)
	greenStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("76"))
	yellowStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	redStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	boldStyle = lipgloss.NewStyle().Bold(true)
)

// menuItem represents a main menu item.
type menuItem struct {
	title string
	desc  string
}

func (m menuItem) Title() string       { return m.title }
func (m menuItem) Description() string { return m.desc }
func (m menuItem) FilterValue() string { return m.title }

// appState tracks which view we're in.
type appState int

const (
	stateMenu appState = iota
	stateInstall
	stateStatus
	stateQR
)

// Model is the top-level Bubble Tea model.
type Model struct {
	state    appState
	version  string
	width    int
	height   int
	menu     list.Model
	install  *installModel
	status   *statusModel
	qr       *qrModel
	quitting bool
}

// Run launches the interactive TUI.
func Run(version string) {
	m := Model{
		state:   stateMenu,
		version: version,
	}
	m.buildMenu()

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// agentInstalled checks if the agent config exists.
func agentInstalled() bool {
	_, err := os.Stat(config.DefaultConfigPath)
	return err == nil
}

// buildMenu creates the menu based on current state.
func (m *Model) buildMenu() {
	var items []list.Item

	if agentInstalled() {
		items = []list.Item{
			menuItem{title: "📊  Status", desc: "Live system health dashboard"},
			menuItem{title: "📱  Show QR Code", desc: "Scan to pair with PiControl app"},
			menuItem{title: "🔄  Update Agent", desc: "Check and apply updates"},
			menuItem{title: "🗑   Uninstall", desc: "Remove agent from this device"},
			menuItem{title: "❌  Exit", desc: "Quit"},
		}
	} else {
		items = []list.Item{
			menuItem{title: "🚀  Install Agent", desc: "Interactive setup wizard"},
			menuItem{title: "📊  System Status", desc: "Live system health dashboard"},
			menuItem{title: "❌  Exit", desc: "Quit"},
		}
	}

	l := list.New(items, list.NewDefaultDelegate(), 60, 15)
	l.Title = ""
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)
	l.Styles.Title = lipgloss.NewStyle()
	m.menu = l
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.menu.SetSize(msg.Width, msg.Height-8)
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			m.quitting = true
			return m, tea.Quit
		}
		if msg.String() == "esc" {
			if m.state != stateMenu {
				m.state = stateMenu
				return m, nil
			}
			m.quitting = true
			return m, tea.Quit
		}
	}

	switch m.state {
	case stateMenu:
		return m.updateMenu(msg)
	case stateInstall:
		return m.updateInstall(msg)
	case stateStatus:
		return m.updateStatus(msg)
	case stateQR:
		return m.updateQR(msg)
	}
	return m, nil
}

func (m Model) updateMenu(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.menu, cmd = m.menu.Update(msg)

	if msg, ok := msg.(tea.KeyMsg); ok && msg.String() == "enter" {
		i, ok := m.menu.SelectedItem().(menuItem)
		if !ok {
			return m, nil
		}
		switch i.title {
		case "🚀  Install Agent":
			m.install = newInstallModel(m.version)
			m.state = stateInstall
			return m, textinput.Blink
		case "📊  Status", "📊 System Status":
			m.status = newStatusModel()
			m.state = stateStatus
			return m, tea.Tick(0, func(t time.Time) tea.Msg {
				return statusRefreshMsg{}
			})
		case "📱  Show QR Code":
			m.qr = newQRModel()
			m.state = stateQR
			return m, nil
		case "🔄  Update Agent":
			// TODO: trigger update via agent API
			return m, nil
		case "🗑   Uninstall":
			// TODO: trigger uninstall
			return m, nil
		case "❌  Exit", "❌ Exit":
			m.quitting = true
			return m, tea.Quit
		}
	}
	return m, cmd
}

func (m Model) updateInstall(msg tea.Msg) (tea.Model, tea.Cmd) {
	im, cmd := m.install.Update(msg)
	if newIm, ok := im.(installModel); ok {
		m.install = &newIm
	}
	if m.install.done {
		m.state = stateMenu
		return m, nil
	}
	return m, cmd
}

func (m Model) updateStatus(msg tea.Msg) (tea.Model, tea.Cmd) {
	sm, cmd := m.status.Update(msg)
	if newSm, ok := sm.(statusModel); ok {
		m.status = &newSm
	}
	return m, cmd
}

func (m Model) updateQR(msg tea.Msg) (tea.Model, tea.Cmd) {
	return m, nil
}

func (m Model) View() string {
	if m.quitting {
		return dimStyle.Render("Goodbye! 👋") + "\n"
	}

	var s strings.Builder
	s.WriteString(boxStyle.Render(lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("36")).Render("🔒 Pi Zero-Trust Agent")))
	s.WriteString("\n")

	switch m.state {
	case stateMenu:
		s.WriteString(m.menu.View())
	case stateInstall:
		s.WriteString(m.install.View())
	case stateStatus:
		s.WriteString(m.status.View())
	case stateQR:
		s.WriteString(m.qr.View())
	}
	return s.String()
}

// ─── Install Wizard ─────────────────────────────

type installStep int

const (
	stepMode installStep = iota
	stepHostname
	stepIotPushConfirm
	stepIotPushKey
	stepIotPushTopic
	stepIotPushValidate
	stepTailscaleKey
	stepAPIToken
	stepConfirm
	stepInstalling
	stepDone
)

type installModel struct {
	step        installStep
	version     string
	cfg         config.Config
	input       textinput.Model
	yesNoCursor int // 0=yes, 1=no
	err         string
	installLog  string
	done        bool
}

func newInstallModel(version string) *installModel {
	ti := textinput.New()
	ti.CharLimit = 200
	// Don't focus until we reach an input step
	return &installModel{
		step:    stepMode,
		version: version,
		cfg:     *config.DefaultConfig(),
		input:   ti,
	}
}

func (m installModel) Init() tea.Cmd {
	return nil
}

func (m installModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			m.done = true
			return m, nil
		}

		switch m.step {
		case stepMode:
			switch msg.String() {
			case "up", "down", "left", "right", "tab", "j", "k":
				if m.yesNoCursor == 0 {
					m.yesNoCursor = 1
				} else {
					m.yesNoCursor = 0
				}
			case "enter":
				m.cfg.Tailscale.Enabled = m.yesNoCursor == 0
				m.step = stepHostname
				m.input.SetValue("")
				m.input.Placeholder = "zerotrust-pi"
				m.input.Prompt = "  Hostname: "
				hostname, _ := os.Hostname()
				if hostname != "" {
					m.input.Placeholder = hostname
				}
				m.input.Focus()
				return m, textinput.Blink
			}

		case stepHostname, stepIotPushKey, stepIotPushTopic, stepTailscaleKey, stepAPIToken:
			if msg.String() == "enter" {
				return m.advanceStep()
			}
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(msg)
			return m, cmd

		case stepIotPushConfirm:
			if msg.String() == "left" || msg.String() == "right" || msg.String() == "tab" {
				if m.yesNoCursor == 0 {
					m.yesNoCursor = 1
				} else {
					m.yesNoCursor = 0
				}
			}
			if msg.String() == "enter" {
				if m.yesNoCursor == 1 { // No
					m.cfg.IotPush.Enabled = false
					if m.cfg.Tailscale.Enabled {
						m.step = stepTailscaleKey
						m.input.SetValue("")
						m.input.Placeholder = "tskey-auth-..."
						m.input.Prompt = "  Tailscale Auth Key: "
						m.input.EchoMode = textinput.EchoPassword
						m.input.Focus()
		return m, textinput.Blink
					}
					m.step = stepAPIToken
					m.input.SetValue("")
					m.input.Placeholder = "(auto-generated)"
					m.input.Prompt = "  API Token: "
					m.input.EchoMode = textinput.EchoNormal
					m.input.Focus()
		return m, textinput.Blink
				}
				m.cfg.IotPush.Enabled = true
				m.step = stepIotPushKey
				m.input.SetValue("")
				m.input.Placeholder = "iotpush_xxx..."
				m.input.Prompt = "  iotPush API Key: "
				m.input.EchoMode = textinput.EchoPassword
				m.input.Focus()
		return m, textinput.Blink
			}

		case stepIotPushValidate:
			// auto-advances

		case stepConfirm:
			if msg.String() == "left" || msg.String() == "right" {
				if m.yesNoCursor == 0 {
					m.yesNoCursor = 1
				} else {
					m.yesNoCursor = 0
				}
			}
			if msg.String() == "enter" {
				if m.yesNoCursor == 0 { // Yes, install
					m.step = stepInstalling
					return m, tea.Tick(0, func(t time.Time) tea.Msg {
						return installStartMsg{}
					})
				}
				m.done = true
				return m, nil
			}

		case stepDone:
			if msg.String() == "enter" {
				m.done = true
				return m, nil
			}
		}
	}

	// Handle installStartMsg
	if _, ok := msg.(installStartMsg); ok {
		m.runInstall()
	}

	return m, nil
}

func (m *installModel) advanceStep() (tea.Model, tea.Cmd) {
	switch m.step {
	case stepHostname:
		val := m.input.Value()
		if val == "" {
			val = m.input.Placeholder
		}
		m.cfg.Agent.Hostname = val
		m.step = stepIotPushConfirm
		m.yesNoCursor = 0

	case stepIotPushKey:
		m.cfg.IotPush.APIKey = m.input.Value()
		m.step = stepIotPushTopic
		m.input.SetValue("")
		m.input.Placeholder = "my-alerts"
		m.input.Prompt = "  iotPush Topic: "
		m.input.EchoMode = textinput.EchoNormal

	case stepIotPushTopic:
		m.cfg.IotPush.Topic = m.input.Value()
		// Validate
		m.step = stepIotPushValidate
		client := iotpush.NewClient(m.cfg.IotPush.APIKey, m.cfg.IotPush.Topic)
		if err := client.Validate(); err != nil {
			m.err = fmt.Sprintf("⚠ Could not verify iotPush: %v", err)
		} else {
			m.err = ""
		}
		// Advance to next step
		if m.cfg.Tailscale.Enabled {
			m.step = stepTailscaleKey
			m.input.SetValue("")
			m.input.Placeholder = "tskey-auth-..."
			m.input.Prompt = "  Tailscale Auth Key: "
			m.input.EchoMode = textinput.EchoPassword
		} else {
			m.step = stepAPIToken
			m.input.SetValue("")
			m.input.Placeholder = "(auto-generated)"
			m.input.Prompt = "  API Token: "
			m.input.EchoMode = textinput.EchoNormal
		}
		m.input.Focus()
		return m, textinput.Blink

	case stepTailscaleKey:
		m.cfg.Tailscale.AuthKey = m.input.Value()
		m.step = stepAPIToken
		m.input.SetValue("")
		m.input.Placeholder = "(auto-generated)"
		m.input.Prompt = "  API Token: "
		m.input.EchoMode = textinput.EchoNormal

	case stepAPIToken:
		m.cfg.Agent.APIToken = m.input.Value()
		m.step = stepConfirm
		m.yesNoCursor = 0

	default:
		return m, nil
	}
	m.input.Focus()
		return m, textinput.Blink
}

type installStartMsg struct{}

func (m *installModel) runInstall() {
	m.installLog = "Installing...\n"
	m.cfg.Agent.Version = m.version
	if m.cfg.Agent.APIToken == "" {
		b := make([]byte, 32)
		rand.Read(b)
		m.cfg.Agent.APIToken = fmt.Sprintf("%x", b)
	}
	// Save config
	if err := m.cfg.Save(config.DefaultConfigPath); err != nil {
		m.installLog += fmt.Sprintf("  ⚠ Config save: %v\n", err)
	} else {
		m.installLog += "  ✓ Config written\n"
	}
	m.installLog += "  ✓ Installation complete!\n"
	m.step = stepDone
}

func (m installModel) View() string {
	var s strings.Builder

	switch m.step {
	case stepMode:
		s.WriteString(titleStyle.Render("  Step 1: Choose your device type"))
		s.WriteString("\n\n")
		if m.yesNoCursor == 0 {
			s.WriteString("  ▸ ")
			s.WriteString(greenStyle.Bold(true).Render("Raspberry Pi (with Tailscale)"))
			s.WriteString("\n")
			s.WriteString("    VPS / Server (no Tailscale)")
		} else {
			s.WriteString("    Raspberry Pi (with Tailscale)")
			s.WriteString("\n")
			s.WriteString("  ▸ ")
			s.WriteString(greenStyle.Bold(true).Render("VPS / Server (no Tailscale)"))
		}
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  ↑↓ or ←→ to select, Enter to confirm"))

	case stepHostname:
		s.WriteString(titleStyle.Render("  Step 2: Set hostname"))
		s.WriteString("\n\n")
		s.WriteString("  " + m.input.View())
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Enter to continue"))

	case stepIotPushConfirm:
		s.WriteString(titleStyle.Render("  Step 3: Configure API keys"))
		s.WriteString("\n\n")
		s.WriteString("  " + boldStyle.Render("iotPush") + " — push notifications")
		s.WriteString("\n")
		s.WriteString(dimStyle.Render("  Get your key: https://iotpush.com/settings"))
		s.WriteString("\n\n")
		if m.yesNoCursor == 0 {
			s.WriteString("  [✓ Yes]  [ No ]")
		} else {
			s.WriteString("  [ Yes ]  [✓ No]")
		}
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  ↑↓ or ←→ to select, Enter to confirm"))

	case stepIotPushKey:
		s.WriteString(titleStyle.Render("  Step 3: iotPush API Key"))
		s.WriteString("\n\n")
		s.WriteString("  " + m.input.View())
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Enter to continue"))

	case stepIotPushTopic:
		s.WriteString(titleStyle.Render("  Step 3: iotPush Topic"))
		s.WriteString("\n\n")
		s.WriteString("  " + m.input.View())
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Enter to continue"))

	case stepIotPushValidate:
		if m.err != "" {
			s.WriteString(yellowStyle.Render(m.err))
		} else {
			s.WriteString(greenStyle.Render("  ✓ iotPush credentials valid — test push sent"))
		}

	case stepTailscaleKey:
		s.WriteString(titleStyle.Render("  Step 3: Tailscale"))
		s.WriteString("\n")
		s.WriteString(dimStyle.Render("  Get your key: https://login.tailscale.com/admin/settings/keys"))
		s.WriteString("\n\n")
		s.WriteString("  " + m.input.View())
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Enter to continue"))

	case stepAPIToken:
		s.WriteString(titleStyle.Render("  Step 4: API Token"))
		s.WriteString("\n\n")
		s.WriteString("  " + m.input.View())
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Leave empty for auto-generated token"))

	case stepConfirm:
		s.WriteString(titleStyle.Render("  ⚡ Ready to install — confirm your settings:"))
		s.WriteString("\n\n")
		mode := "VPS"
		if m.cfg.Tailscale.Enabled {
			mode = "Pi"
		}
		s.WriteString(fmt.Sprintf("  Mode:      %s\n", greenStyle.Render(mode)))
		s.WriteString(fmt.Sprintf("  Hostname:  %s\n", greenStyle.Render(m.cfg.Agent.Hostname)))
		if m.cfg.IotPush.Enabled {
			s.WriteString(fmt.Sprintf("  iotPush:   %s\n", greenStyle.Render("configured")))
		} else {
			s.WriteString(fmt.Sprintf("  iotPush:   %s\n", dimStyle.Render("skipped")))
		}
		if m.cfg.Tailscale.Enabled {
			s.WriteString(fmt.Sprintf("  Tailscale: %s\n", greenStyle.Render("enabled")))
		} else {
			s.WriteString(fmt.Sprintf("  Tailscale: %s\n", dimStyle.Render("disabled")))
		}
		s.WriteString("\n")
		if m.yesNoCursor == 0 {
			s.WriteString("  [✓ Install]  [ Cancel ]")
		} else {
			s.WriteString("  [ Install ]  [✓ Cancel]")
		}

	case stepInstalling:
		s.WriteString(titleStyle.Render("  🚀 Installing..."))
		s.WriteString("\n\n")
		s.WriteString(m.installLog)

	case stepDone:
		s.WriteString(successBoxStyle.Render(lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("76")).Render("✅ Setup Complete!")))
		s.WriteString("\n\n")
		tsIP := system.GetTailscaleIP()
		if tsIP == "" {
			tsIP = system.GetInfo().LocalIP
		}
		s.WriteString(fmt.Sprintf("  Hostname:  %s\n", greenStyle.Render(m.cfg.Agent.Hostname)))
		if m.cfg.Tailscale.Enabled {
			s.WriteString(fmt.Sprintf("  Tailscale: %s\n", greenStyle.Render(tsIP)))
		}
		s.WriteString(fmt.Sprintf("  API:       %s\n", greenStyle.Render(fmt.Sprintf("http://%s:8080", tsIP))))
		s.WriteString(fmt.Sprintf("  Token:     %s\n", yellowStyle.Render(m.cfg.Agent.APIToken)))
		s.WriteString("\n")
		s.WriteString(dimStyle.Render("  Press Enter to return to menu"))
	}

	s.WriteString("\n\n")
	s.WriteString(dimStyle.Render("  Esc → back  Ctrl+C → quit"))
	return s.String()
}

// ─── Status View ─────────────────────────────

type statusRefreshMsg struct{}
type statusModel struct {
	stats system.Stats
	info  system.Info
}

func newStatusModel() *statusModel {
	return &statusModel{
		stats: system.GetStats(),
		info:  system.GetInfo(),
	}
}

func (m statusModel) Init() tea.Cmd {
	return nil
}

func (m statusModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := msg.(statusRefreshMsg); ok {
		m.stats = system.GetStats()
		m.info = system.GetInfo()
		return m, tea.Tick(2*time.Second, func(t time.Time) tea.Msg {
			return statusRefreshMsg{}
		})
	}
	return m, nil
}

func (m statusModel) View() string {
	var s strings.Builder
	s.WriteString(titleStyle.Render("  📊 System Status"))
	s.WriteString("\n\n")

	s.WriteString(fmt.Sprintf("  Hostname:    %s\n", m.info.Hostname))
	s.WriteString(fmt.Sprintf("  Platform:    %s/%s\n", m.info.Platform, m.info.Architecture))
	s.WriteString(fmt.Sprintf("  Uptime:      %s\n", system.FormatUptime(m.stats.UptimeSeconds)))

	cpuBar := progressBar(m.stats.CPUPercent, 100)
	s.WriteString(fmt.Sprintf("  CPU:         %s %.1f%%\n", cpuBar, m.stats.CPUPercent))

	memBar := progressBar(m.stats.MemUsedMB, m.stats.MemTotalMB)
	s.WriteString(fmt.Sprintf("  Memory:      %s %.0f/%.0f MB\n", memBar, m.stats.MemUsedMB, m.stats.MemTotalMB))

	diskBar := progressBar(m.stats.DiskUsedGB, m.stats.DiskTotalGB)
	s.WriteString(fmt.Sprintf("  Disk:        %s %.1f/%.1f GB\n", diskBar, m.stats.DiskUsedGB, m.stats.DiskTotalGB))

	if m.stats.Temperature != nil {
		temp := *m.stats.Temperature
		tempStr := fmt.Sprintf("%.1f°C", temp)
		if temp > 70 {
			tempStr = redStyle.Render(tempStr)
		} else if temp > 50 {
			tempStr = yellowStyle.Render(tempStr)
		} else {
			tempStr = greenStyle.Render(tempStr)
		}
		s.WriteString(fmt.Sprintf("  Temperature: %s\n", tempStr))
	}

	if m.stats.TailscaleIP != "" {
		s.WriteString(fmt.Sprintf("  Tailscale:   %s\n", greenStyle.Render(m.stats.TailscaleIP)))
	}

	if m.info.IsPi {
		s.WriteString(fmt.Sprintf("  Pi Model:    %s\n", m.info.PiModel))
	}

	s.WriteString(fmt.Sprintf("  Load:        %.2f %.2f %.2f\n", m.stats.LoadAvg[0], m.stats.LoadAvg[1], m.stats.LoadAvg[2]))

	s.WriteString("\n")
	s.WriteString(dimStyle.Render("  Auto-refreshing every 2s • Esc → back"))
	return s.String()
}

func progressBar(current, total float64) string {
	width := 20
	var pct float64
	if total > 0 {
		pct = current / total
	}
	filled := int(pct * float64(width))
	if filled > width {
		filled = width
	}
	bar := strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
	return bar
}

// ─── QR Code View ─────────────────────────────

type qrModel struct {
	qrString string
	png      []byte
}

func newQRModel() *qrModel {
	m := &qrModel{}
	info := system.GetInfo()
	tsIP := info.TailscaleIP
	if tsIP == "" {
		tsIP = info.LocalIP
	}
	m.qrString = fmt.Sprintf("http://%s:8080", tsIP)

	png, err := qrcode.Encode(m.qrString, qrcode.Medium, 256)
	if err != nil {
		m.qrString = fmt.Sprintf("Error generating QR: %v", err)
	} else {
		m.png = png
	}
	return m
}

func (m qrModel) Init() tea.Cmd {
	return nil
}

func (m qrModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	return m, nil
}

func (m qrModel) View() string {
	var s strings.Builder
	s.WriteString(titleStyle.Render("  📱 QR Code — Mobile Pairing"))
	s.WriteString("\n\n")

	// Render QR as ASCII art
	if m.png != nil {
		qr, err := qrcode.New(m.qrString, qrcode.Medium)
		if err == nil {
			s.WriteString(qr.ToSmallString(false))
		}
	}

	s.WriteString("\n")
	s.WriteString(fmt.Sprintf("  URL: %s\n", greenStyle.Render(m.qrString)))
	s.WriteString("\n")
	s.WriteString(dimStyle.Render("  Scan with your phone • Esc → back"))
	return s.String()
}
