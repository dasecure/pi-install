package iotpush

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const DefaultBaseURL = "https://www.iotpush.com/api"

// Client is a Go client wrapper for the iotPush API.
type Client struct {
	BaseURL    string
	APIKey     string
	Topic      string
	HTTPClient *http.Client
	MaxRetries int
	RetryDelay time.Duration
}

// NewClient creates a new iotPush client.
func NewClient(apiKey, topic string) *Client {
	return &Client{
		BaseURL:    DefaultBaseURL,
		APIKey:     apiKey,
		Topic:      topic,
		HTTPClient: &http.Client{Timeout: 10 * time.Second},
		MaxRetries: 3,
		RetryDelay: 2 * time.Second,
	}
}

// PushPayload represents an iotPush notification payload.
type PushPayload struct {
	Title    string `json:"title"`
	Message  string `json:"message"`
	Priority string `json:"priority,omitempty"`
	Tags     string `json:"tags,omitempty"`
	ClickURL string `json:"click_url,omitempty"`
}

// PushResponse represents the API response.
type PushResponse struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
}

// Push sends a notification via iotPush with retry logic.
func (c *Client) Push(title, message string) error {
	payload := PushPayload{
		Title:   title,
		Message: message,
	}
	return c.PushWithPayload(payload)
}

// PushWithPriority sends a notification with specified priority.
func (c *Client) PushWithPriority(title, message, priority string) error {
	payload := PushPayload{
		Title:     title,
		Message:   message,
		Priority:  priority,
	}
	return c.PushWithPayload(payload)
}

// PushWithPayload sends a fully customized notification.
func (c *Client) PushWithPayload(payload PushPayload) error {
	if c.APIKey == "" || c.Topic == "" {
		return fmt.Errorf("iotPush not configured: missing API key or topic")
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	url := fmt.Sprintf("%s/push/%s", c.BaseURL, c.Topic)

	var lastErr error
	for attempt := 0; attempt < c.MaxRetries; attempt++ {
		if attempt > 0 {
			time.Sleep(c.RetryDelay * time.Duration(attempt))
		}

		req, err := http.NewRequest("POST", url, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("create request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
		req.Header.Set("Content-Type", "application/json")

		resp, err := c.HTTPClient.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("request failed (attempt %d/%d): %w", attempt+1, c.MaxRetries, err)
			continue
		}

		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode == 200 {
			return nil
		}

		lastErr = fmt.Errorf("iotPush API returned %d: %s", resp.StatusCode, string(respBody))
	}

	return lastErr
}

// Validate tests the iotPush credentials by sending a test push.
func (c *Client) Validate() error {
	return c.Push("Pi Setup Test", "iotPush credentials verified during setup")
}
