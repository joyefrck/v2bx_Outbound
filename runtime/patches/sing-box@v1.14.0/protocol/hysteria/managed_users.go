package hysteria

import (
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.HysteriaUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.AuthString
	}
	h.service.UpdateUsers(names, secrets)
	h.managedUsers = append([]option.HysteriaUser(nil), users...)
	return nil
}
