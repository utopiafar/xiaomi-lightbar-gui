package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Config holds persistent CLI settings.
type Config struct {
	Port string `json:"port,omitempty"`
	ID   string `json:"id,omitempty"`
}

func filePath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "lamp", "config.json"), nil
}

// Path returns the config file location for display purposes.
func Path() string {
	p, err := filePath()
	if err != nil {
		return "(unknown)"
	}
	return p
}

// Load reads the config file. Returns an empty Config on any error.
func Load() *Config {
	p, err := filePath()
	if err != nil {
		return &Config{}
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return &Config{}
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return &Config{}
	}
	return &cfg
}

// Save writes the config to disk atomically.
func (c *Config) Save() error {
	p, err := filePath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o600)
}
