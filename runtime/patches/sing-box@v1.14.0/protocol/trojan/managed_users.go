package trojan

import (
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.TrojanUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.Password
	}
	if err := h.service.UpdateUsers(names, secrets); err != nil {
		return err
	}
	h.managedUsers = append([]option.TrojanUser(nil), users...)
	return nil
}
