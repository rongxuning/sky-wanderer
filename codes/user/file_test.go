package user

import (
	"context"
	"path/filepath"
	"testing"
)

func TestFileRepositorySurvivesReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth-store.json")
	repo, err := NewFileRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	auth := NewService(ServiceOptions{Repo: repo, Demo: true})
	first, err := auth.LoginOrRegister(context.Background(), LoginInput{
		Type: "phone", ProviderSubject: "13800138000", DemoCode: str(DemoCode), DisplayName: str("小林"),
	})
	if err != nil || !first.Created {
		t.Fatal(err)
	}
	reloaded, err := NewFileRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	again := NewService(ServiceOptions{Repo: reloaded, Demo: true})
	second, err := again.LoginOrRegister(context.Background(), LoginInput{
		Type: "phone", ProviderSubject: "+86 138-0013-8000", DemoCode: str(DemoCode),
	})
	if err != nil || second.Created || second.User.ID != first.User.ID || second.User.DisplayName != "小林" {
		t.Fatalf("%v %#v", err, second)
	}
}
