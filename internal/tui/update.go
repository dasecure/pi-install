package tui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/dasecure/pi-install/internal/config"
	"github.com/dasecure/pi-install/internal/system"
)

// updateState tracks the update flow.
type updateState int

const (
	updateChecking updateState = iota
	updateAvailable
	updateUpToDate
	updateConfirm
	updateRunning
	updateDone
	updateError
)

type updateModel struct {
	state       updateState
	currentVer  string
	latestVer   string
	releaseNotes string
	err         string
	agentURL    string
	apiToken    string
	yesNoCursor int
}

func newUpdateModel() *updateModel {
	m := &updateModel{
		state: updateChecking,
	}

	// Get agent address
	cfg, err := loadConfig()
	if err != nil {
		m.state = updateError
		m.err = "Agent not installed"
		return m
	}

	ip := getAgentIP()
	m.agentURL = fmt.Sprintf("http://%s:%d", ip, cfg.Agent.Port)
	m.apiToken = cfg.Agent.APIToken
	m.currentVer = cfg.Agent.Version

	return m
}

func (m *updateModel) Init() tea.Cmd {
	if m.state == updateChecking {
		return tea.Tick(0, func(t time.Time) tea.Msg {
			return checkUpdateMsg{}
		})
	}
	return nil
}

func (m *updateModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "esc":
			m.state = updateChecking // reset for next time
			return m, nil // parent handles escape
		case "up", "down", "left", "right", "tab":
			if m.state == updateConfirm {
				if m.yesNoCursor == 0 {
					m.yesNoCursor = 1
				} else {
					m.yesNoCursor = 0
				}
			}
		case "enter":
			switch m.state {
			case updateConfirm:
				if m.yesNoCursor == 0 {
					m.state = updateRunning
					return m, tea.Tick(0, func(t time.Time) tea.Msg {
						return runUpdateMsg{}
					})
				}
				return m, nil // cancelled
			case updateDone, updateUpToDate, updateError:
				return m, nil // parent handles
			}
		}

	case checkUpdateMsg:
		m.checkForUpdate()

	case runUpdateMsg:
		m.runUpdate()
	}

	return m, nil
}

func (m *updateModel) View() string {
	var s strings.Builder
	s.WriteString(titleStyle.Render("  🔄 Update Agent"))
	s.WriteString("\n\n")

	switch m.state {
	case updateChecking:
		s.WriteString("  Checking for updates...")

	case updateUpToDate:
		s.WriteString(greenStyle.Render(fmt.Sprintf("  ✓ Already up to date (v%s)", m.currentVer)))
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Press Esc to go back"))

	case updateAvailable:
		s.WriteString(fmt.Sprintf("  Current:  %s\n", dimStyle.Render("v"+m.currentVer)))
		s.WriteString(fmt.Sprintf("  Latest:   %s\n", greenStyle.Render("v"+m.latestVer)))
		if m.releaseNotes != "" {
			s.WriteString("\n")
			for _, line := range strings.Split(m.releaseNotes, "\n") {
				s.WriteString("  " + dimStyle.Render(line) + "\n")
			}
		}
		s.WriteString("\n")
		if m.yesNoCursor == 0 {
			s.WriteString("  [✓ Update]  [ Cancel ]")
		} else {
			s.WriteString("  [ Update ]  [✓ Cancel]")
		}
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  ↑↓ to select • Enter to confirm"))

	case updateConfirm:
		if m.yesNoCursor == 0 {
			s.WriteString("  [✓ Update]  [ Cancel ]")
		} else {
			s.WriteString("  [ Update ]  [✓ Cancel]")
		}

	case updateRunning:
		s.WriteString(yellowStyle.Render("  Updating..."))
		s.WriteString("\n")
		s.WriteString(dimStyle.Render("  Downloading and installing new version"))

	case updateDone:
		s.WriteString(greenStyle.Render(fmt.Sprintf("  ✓ Updated to v%s!", m.latestVer)))
		s.WriteString("\n")
		s.WriteString(dimStyle.Render("  Agent is restarting..."))
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Press Esc to go back"))

	case updateError:
		s.WriteString(redStyle.Render(fmt.Sprintf("  ✗ %s", m.err)))
		s.WriteString("\n\n")
		s.WriteString(dimStyle.Render("  Press Esc to go back"))
	}

	return s.String()
}

func (m *updateModel) checkForUpdate() {
	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest("GET", m.agentURL+"/check-update", nil)
	if err != nil {
		m.state = updateError
		m.err = fmt.Sprintf("create request: %v", err)
		return
	}
	req.Header.Set("X-API-Token", m.apiToken)

	resp, err := client.Do(req)
	if err != nil {
		m.state = updateError
		m.err = "Cannot reach agent — is it running?"
		return
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		m.state = updateError
		m.err = "Invalid response from agent"
		return
	}

	available, _ := result["update_available"].(bool)
	latest, _ := result["latest_version"].(string)
	notes, _ := result["release_notes"].(string)
	current, _ := result["current_version"].(string)

	if current != "" {
		m.currentVer = current
	}

	if available {
		m.state = updateAvailable
		m.latestVer = latest
		m.releaseNotes = notes
		m.yesNoCursor = 0
	} else {
		m.state = updateUpToDate
	}
}

func (m *updateModel) runUpdate() {
	client := &http.Client{Timeout: 180 * time.Second}
	req, err := http.NewRequest("POST", m.agentURL+"/update", nil)
	if err != nil {
		m.state = updateError
		m.err = fmt.Sprintf("create request: %v", err)
		return
	}
	req.Header.Set("X-API-Token", m.apiToken)

	resp, err := client.Do(req)
	if err != nil {
		m.state = updateError
		m.err = "Cannot reach agent for update"
		return
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		m.state = updateError
		m.err = "Invalid response"
		return
	}

	success, _ := result["success"].(bool)
	msg, _ := result["message"].(string)
	if !success {
		errMsg, _ := result["error"].(string)
		m.state = updateError
		m.err = errMsg
		if m.err == "" {
			m.err = msg
		}
		return
	}

	m.state = updateDone
	if to, ok := result["to"].(string); ok {
		m.latestVer = to
	}
}

type checkUpdateMsg struct{}
type runUpdateMsg struct{}

// Helpers

func loadConfig() (*config.Config, error) {
	return config.Load(config.DefaultConfigPath)
}

func getAgentIP() string {
	if tsIP := system.GetTailscaleIP(); tsIP != "" {
		return tsIP
	}
	return system.GetInfo().LocalIP
}
