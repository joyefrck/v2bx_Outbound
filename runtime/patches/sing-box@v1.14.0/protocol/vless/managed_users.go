package vless

import (
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.VLESSUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	flows := make([]string, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.UUID
		flows[i] = u.Flow
	}
	h.service.UpdateUsers(names, secrets, flows)
	h.managedUsers = append([]option.VLESSUser(nil), users...)
	return nil
}
