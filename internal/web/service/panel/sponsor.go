package panel

import (
	"errors"
	"time"
)

// Sponsor preserves the upstream API schema for existing panel clients.
type Sponsor struct {
	ID     string            `json:"id" example:"acme-2026-10"`
	Name   string            `json:"name" example:"Acme VPS"`
	Enable *bool             `json:"enable,omitempty" example:"true"`
	Slots  []string          `json:"slots"`
	From   *time.Time        `json:"from,omitempty" example:"2026-10-01T00:00:00Z"`
	Until  time.Time         `json:"until" example:"2026-11-01T00:00:00Z"`
	Logo   string            `json:"logo,omitempty" example:"/sponsors/logo/acme.png"`
	Title  map[string]string `json:"title"`
	Text   map[string]string `json:"text"`
	Link   string            `json:"link" example:"https://acme.example/?utm_source=3x-ui"`
}

// SponsorList keeps the response compatible without publishing paid placements.
type SponsorList struct {
	Contact  string    `json:"contact,omitempty" example:"https://t.me/example"`
	Sponsors []Sponsor `json:"sponsors"`
}

// ErrSponsorLogoUnknown makes the existing logo route return HTTP 404.
var ErrSponsorLogoUnknown = errors.New("unknown sponsor logo")

// GetSponsors disables advertising locally without fetching or caching remote data.
func (s *PanelService) GetSponsors() (*SponsorList, error) {
	return &SponsorList{Sponsors: []Sponsor{}}, nil
}

// GetSponsorLogo refuses every logo without contacting a sponsor image server.
func (s *PanelService) GetSponsorLogo(_ string) ([]byte, string, error) {
	return nil, "", ErrSponsorLogoUnknown
}
