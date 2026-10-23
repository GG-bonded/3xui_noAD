package controller

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestNoAdSponsorHTTPResponses(t *testing.T) {
	// Register only public advertising handlers; no database or credentials are needed.
	engine := gin.New()
	controller := &IndexController{}
	engine.GET("/sponsors", controller.sponsors)
	engine.GET("/sponsors/logo/:name", controller.sponsorLogo)

	list := httptest.NewRecorder()
	engine.ServeHTTP(list, httptest.NewRequest(http.MethodGet, "/sponsors", nil))
	var response struct {
		Success bool `json:"success"`
		Obj     struct {
			Contact  string            `json:"contact"`
			Sponsors []json.RawMessage `json:"sponsors"`
		} `json:"obj"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if list.Code != http.StatusOK || !response.Success || response.Obj.Contact != "" ||
		response.Obj.Sponsors == nil || len(response.Obj.Sponsors) != 0 {
		t.Fatalf("unexpected sponsor response: status=%d body=%s", list.Code, list.Body.String())
	}

	logo := httptest.NewRecorder()
	engine.ServeHTTP(logo, httptest.NewRequest(http.MethodGet, "/sponsors/logo/logo.png", nil))
	if logo.Code != http.StatusNotFound || logo.Body.Len() != 0 {
		t.Fatalf("unexpected logo response: status=%d body=%s", logo.Code, logo.Body.String())
	}
}
