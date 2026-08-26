package gobackend

import "testing"

func TestOverlayExtensionReleaseMetadataFillsMissingRequestFields(t *testing.T) {
	req := DownloadRequest{AlbumType: "single"}
	track := ExtTrackMetadata{
		AlbumType: "album",
		Explicit:  true,
		UPC:       "4006381333931",
		Comment:   "https://music.apple.com/jp/album/1532211596",
	}

	overlayExtensionReleaseMetadata(&req, track)

	if req.AlbumType != "single" {
		t.Fatalf("existing album type was overwritten: %q", req.AlbumType)
	}
	if !req.Explicit {
		t.Fatal("explicit flag from source enrichment was not retained")
	}
	if req.UPC != track.UPC {
		t.Fatalf("UPC = %q, want %q", req.UPC, track.UPC)
	}
	if req.Comment != track.Comment {
		t.Fatalf("comment = %q, want %q", req.Comment, track.Comment)
	}

	response := buildDownloadSuccessResponse(
		req,
		DownloadResult{},
		"amazon",
		"downloaded",
		"song.m4a",
		false,
	)
	if response.UPC != track.UPC || response.AlbumType != "single" ||
		!response.Explicit || response.Comment != track.Comment {
		t.Fatalf("enriched metadata was lost in download response: %#v", response)
	}
}

func TestOverlayExtensionReleaseMetadataDoesNotEraseExistingValues(t *testing.T) {
	req := DownloadRequest{
		AlbumType: "ep",
		Explicit:  true,
		UPC:       "existing-upc",
		Comment:   "existing-comment",
	}

	overlayExtensionReleaseMetadata(&req, ExtTrackMetadata{})

	if req.AlbumType != "ep" || !req.Explicit ||
		req.UPC != "existing-upc" || req.Comment != "existing-comment" {
		t.Fatalf("existing release metadata changed: %#v", req)
	}
}
