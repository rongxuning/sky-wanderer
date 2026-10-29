package user

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"time"
)

func NewFileRepository(path string) (Repository, error) {
	data, err := readMemoryFile(path)
	if err != nil {
		return nil, err
	}
	repo := &memoryRepo{data: data}
	repo.onChange = func() {
		if err := writeMemoryFile(path, repo.data); err != nil {
			log.Printf("auth store write: %v", err)
		}
	}
	return repo, nil
}

func readMemoryFile(path string) (*MemoryData, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return EmptyMemory(), nil
		}
		return nil, err
	}
	var parsed MemoryData
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}
	normalizeMemory(&parsed)
	fallback := FormatTime(time.Now().Add(30 * 24 * time.Hour))
	kept := parsed.Sessions[:0]
	for _, session := range parsed.Sessions {
		if session.Token == "" || session.UserID == "" || session.CreatedAt == "" {
			continue
		}
		if session.ExpiresAt == "" {
			session.ExpiresAt = fallback
		}
		kept = append(kept, session)
	}
	parsed.Sessions = kept
	return &parsed, nil
}

func writeMemoryFile(path string, data *MemoryData) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return os.WriteFile(path, raw, 0o644)
}
