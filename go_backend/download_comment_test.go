package gobackend

import "testing"

func TestBuildDownloadedFileCommentKeepsSourceLinkAndAddsCredit(t *testing.T) {
	const source = "https://music.apple.com/us/album/example/123"
	got := buildDownloadedFileComment(source, "https://music.amazon.com/albums/example")
	want := source + "\n" + downloadCommentCredit
	if got != want {
		t.Fatalf("comment = %q, want %q", got, want)
	}
}

func TestBuildDownloadedFileCommentUsesProviderCommentWhenSourceIsEmpty(t *testing.T) {
	const provider = "https://music.amazon.com/albums/example"
	got := buildDownloadedFileComment("", provider)
	want := provider + "\n" + downloadCommentCredit
	if got != want {
		t.Fatalf("comment = %q, want %q", got, want)
	}
}

func TestBuildDownloadedFileCommentAddsCreditWithoutLink(t *testing.T) {
	if got := buildDownloadedFileComment("", ""); got != downloadCommentCredit {
		t.Fatalf("comment = %q, want credit only", got)
	}
}

func TestBuildDownloadedFileCommentDoesNotDuplicateCredit(t *testing.T) {
	original := "https://example.test/album/1\n" + downloadCommentCredit
	if got := buildDownloadedFileComment(original, ""); got != original {
		t.Fatalf("credit was duplicated: %q", got)
	}
}
