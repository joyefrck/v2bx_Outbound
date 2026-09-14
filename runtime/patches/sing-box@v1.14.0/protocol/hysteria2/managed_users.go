package hysteria2

import (
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.Hysteria2User) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.Password
	}
	h.service.UpdateUsers(names, secrets)
	h.managedUsers = append([]option.Hysteria2User(nil), users...)
	return nil
}
