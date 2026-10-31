package limiter

import (
	"errors"
	"regexp"

	"github.com/InazumaV/V2bX/api/panel"
)

func (l *Limiter) CheckDomainRule(destination string) (reject bool) {
	// have rule
	for i := range l.DomainRules {
		if l.DomainRules[i].MatchString(destination) {
			reject = true
			break
		}
	}
	return
}

func (l *Limiter) CheckProtocolRule(protocol string) (reject bool) {
	for i := range l.ProtocolRules {
		if l.ProtocolRules[i] == protocol {
			reject = true
			break
		}
	}
	return
}

func (l *Limiter) UpdateRule(rule *panel.Rules) error {
	compiled := make([]*regexp.Regexp, len(rule.Regexp))
	for i := range rule.Regexp {
		value, err := regexp.Compile(rule.Regexp[i])
		if err != nil {
			return errors.New("invalid domain rule expression")
		}
		compiled[i] = value
	}
	l.DomainRules = compiled
	l.ProtocolRules = append([]string(nil), rule.Protocol...)
	return nil
}
