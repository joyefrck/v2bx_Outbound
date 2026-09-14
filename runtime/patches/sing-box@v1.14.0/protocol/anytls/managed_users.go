package anytls

import (
	anytls "github.com/anytls/sing-anytls"
	"github.com/sagernet/sing-box/option"
)

func (h *Inbound) SetManagedUsers(users []option.AnyTLSUser) error {
	h.managedMu.Lock()
	defer h.managedMu.Unlock()
	list := make([]anytls.User, len(users))
	for i, u := range users {
		list[i] = anytls.User(u)
	}
	h.service.UpdateUsers(list)
	h.managedUsers = append([]option.AnyTLSUser(nil), users...)
	return nil
}
