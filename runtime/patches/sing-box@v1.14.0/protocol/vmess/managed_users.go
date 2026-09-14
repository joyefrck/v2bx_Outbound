package vmess

import (
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.VMessUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	alters := make([]int, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.UUID
		alters[i] = u.AlterId
	}
	if err := h.service.UpdateUsers(names, secrets, alters); err != nil {
		return err
	}
	h.managedUsers = append([]option.VMessUser(nil), users...)
	return nil
}
