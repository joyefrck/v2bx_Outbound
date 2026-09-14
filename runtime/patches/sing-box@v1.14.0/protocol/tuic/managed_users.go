package tuic

import (
	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.TUICUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	names := make([]string, len(users))
	secrets := make([]string, len(users))
	ids := make([][16]byte, len(users))
	for i, u := range users {
		names[i] = u.Name
		secrets[i] = u.Password
		id, err := uuid.FromString(u.UUID)
		if err != nil {
			return err
		}
		ids[i] = id
	}
	h.server.UpdateUsers(names, ids, secrets)
	h.managedUsers = append([]option.TUICUser(nil), users...)
	return nil
}
