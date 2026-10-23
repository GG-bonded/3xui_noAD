package panel

import (
	"encoding/json"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
)

type sponsorNetworkTripwire struct {
	hits atomic.Int32
}

// RoundTrip fails the test if an advertising method attempts outbound HTTP.
func (t *sponsorNetworkTripwire) RoundTrip(*http.Request) (*http.Response, error) {
	t.hits.Add(1)
	return nil, errors.New("advertising network access is disabled")
}

func TestNoAdSponsorsDoNotAccessNetwork(t *testing.T) {
	tripwire := &sponsorNetworkTripwire{}
	original := http.DefaultTransport
	http.DefaultTransport = tripwire
	t.Cleanup(func() { http.DefaultTransport = original })

	for _, debug := range []string{"false", "true"} {
		t.Run(debug, func(t *testing.T) {
			t.Setenv("XUI_DEBUG", debug)
			service := &PanelService{}
			for range 3 {
				list, err := service.GetSponsors()
				if err != nil || list == nil {
					t.Fatalf("GetSponsors() = %+v, %v; want an empty successful response", list, err)
				}
				encoded, err := json.Marshal(list)
				if err != nil || string(encoded) != `{"sponsors":[]}` {
					t.Fatalf("response = %s, %v; want a non-null empty list and no contact link", encoded, err)
				}
			}
		})
	}
	if got := tripwire.hits.Load(); got != 0 {
		t.Fatalf("outbound advertising requests = %d, want 0", got)
	}
}

func TestNoAdSponsorResponsesAreIndependent(t *testing.T) {
	service := &PanelService{}
	first, err := service.GetSponsors()
	if err != nil {
		t.Fatal(err)
	}
	first.Contact = "https://example.invalid/"
	first.Sponsors = append(first.Sponsors, Sponsor{ID: "cached-ad"})
	second, err := service.GetSponsors()
	if err != nil || second.Contact != "" || len(second.Sponsors) != 0 {
		t.Fatalf("a modified prior response affected the next request: %+v, %v", second, err)
	}
}

func TestNoAdSponsorLogosAreUnavailable(t *testing.T) {
	service := &PanelService{}
	for _, name := range []string{"logo.png", "Nexora.webp", "../logo.png", "https://example.invalid/logo.jpg", ""} {
		t.Run(name, func(t *testing.T) {
			data, contentType, err := service.GetSponsorLogo(name)
			if data != nil || contentType != "" || !errors.Is(err, ErrSponsorLogoUnknown) {
				t.Fatalf("GetSponsorLogo(%q) = %v, %q, %v; want the disabled logo response", name, data, contentType, err)
			}
		})
	}
}
