package gobackend

import "testing"

func TestNormalizeLooseTitle_Separators(t *testing.T) {
	got := normalizeLooseTitle("Doctor / Cops")
	if got != "doctor cops" {
		t.Fatalf("expected doctor cops, got %q", got)
	}

	got = normalizeLooseTitle("Doctor _ Cops")
	if got != "doctor cops" {
		t.Fatalf("expected doctor cops, got %q", got)
	}
}

func TestNormalizeLooseTitle_EmojiAndSymbols(t *testing.T) {
	got := normalizeLooseTitle("Music Of The Spheres 🌎✨")
	if got != "music of the spheres" {
		t.Fatalf("expected music of the spheres, got %q", got)
	}
}

func TestTrackMatchesRequest_SongLinkBypassesArtistAndTitle(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Ringišpil",
		ArtistName: "Djordje Balasevic",
	}
	resolved := resolvedTrackInfo{
		Title:                "Completely Different Title",
		ArtistName:           "Totally Different Artist",
		SkipNameVerification: true,
	}

	if !trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected SongLink-resolved track to bypass artist/title verification")
	}
}

func TestTrackMatchesRequest_SongLinkStillChecksDuration(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Ringišpil",
		ArtistName: "Djordje Balasevic",
		DurationMS: 180000,
	}
	resolved := resolvedTrackInfo{
		Title:                "Completely Different Title",
		ArtistName:           "Totally Different Artist",
		Duration:             240,
		SkipNameVerification: true,
	}

	if trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected SongLink-resolved track with large duration mismatch to be rejected")
	}
}

func TestTrackMatchesRequestRejectsDifferentAlbumWithoutExactISRC(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Bewafa",
		ArtistName: "Imran Khan",
		AlbumName:  "Unforgettable",
		ISRC:       "GBUM70901234",
	}
	resolved := resolvedTrackInfo{
		Title:      "Bewafa",
		ArtistName: "Imran Khan, Tarandeep Singh",
		AlbumName:  "Bewafa",
		ISRC:       "QZXYZ2600001",
	}

	if trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected same-title cover from a different album to be rejected")
	}
}

func TestTrackMatchesRequestAcceptsDifferentEditionWithExactISRC(t *testing.T) {
	req := DownloadRequest{
		TrackName: "Song",
		AlbumName: "Original Album",
		ISRC:      "USRC17607839",
	}
	resolved := resolvedTrackInfo{
		Title:     "Song",
		AlbumName: "Deluxe Collection",
		ISRC:      "usrc17607839",
	}

	if !trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected an exact ISRC match to accept another release edition")
	}
}

func TestTrackMatchesRequestAcceptsSameTrackFromDifferentRelease(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Crossing Field",
		ArtistName: "LiSA",
		AlbumName:  "Crossing Field - EP",
		DurationMS: 233000,
	}
	resolved := resolvedTrackInfo{
		Title:      "Crossing Field",
		ArtistName: "LiSA",
		AlbumName:  "LANDSPACE",
		Duration:   233,
	}

	if !trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected the same track to be accepted across release albums")
	}
}

func TestTrackMatchesRequestRejectsAlbumMismatchForDifferentVersion(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Song (Live)",
		ArtistName: "Artist",
		AlbumName:  "Live at the Theatre",
	}
	resolved := resolvedTrackInfo{
		Title:      "Song",
		ArtistName: "Artist",
		AlbumName:  "Studio Album",
	}

	if trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected an album mismatch to reject a different track version")
	}
}

func TestTrackMatchesRequestRejectsConflictingISRCDespiteStrongNames(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Song",
		ArtistName: "Artist",
		AlbumName:  "Original Album",
		ISRC:       "USAAA2600001",
	}
	resolved := resolvedTrackInfo{
		Title:      "Song",
		ArtistName: "Artist",
		AlbumName:  "Other Album",
		ISRC:       "USAAA2600002",
	}

	if trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected conflicting ISRCs to keep album verification strict")
	}
}

func TestTrackMatchesRequestRejectsDurationMismatchAcrossReleases(t *testing.T) {
	req := DownloadRequest{
		TrackName:  "Crossing Field",
		ArtistName: "LiSA",
		AlbumName:  "Crossing Field - EP",
		DurationMS: 233000,
	}
	resolved := resolvedTrackInfo{
		Title:      "Crossing Field",
		ArtistName: "LiSA",
		AlbumName:  "LANDSPACE",
		Duration:   280,
	}

	if trackMatchesRequest(req, resolved, "test") {
		t.Fatal("expected a large duration mismatch to reject another recording")
	}
}

func TestTitlesMatch_SeparatorVariants(t *testing.T) {
	if !titlesMatch("Doctor / Cops", "Doctor _ Cops") {
		t.Fatal("expected tidal titlesMatch to accept / vs _ variant")
	}
}

func TestTitlesMatch_EmojiStrict(t *testing.T) {
	if titlesMatch("🪐", "Higher Power") {
		t.Fatal("expected emoji title not to match unrelated textual title")
	}
	if !titlesMatch("🪐", "🪐") {
		t.Fatal("expected identical emoji titles to match")
	}
}
