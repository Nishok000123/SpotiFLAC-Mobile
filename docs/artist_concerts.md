# Artist concerts

Any metadata extension can include an optional `concerts` list in `getArtist`
or the `artist` object returned by `handleUrl`. The native metadata bridge
preserves it as `artist_info.concerts` or `artist.concerts`, respectively.
Older extensions may omit it; no concert button is shown for an empty list.

```json
{
  "concerts": [{
    "id": "event-123",
    "location": "Example City, Region",
    "venue": "Example Hall",
    "start_at": "2026-10-07T01:00:00Z",
    "time_zone": "America/New_York",
    "url": "https://example.com/events/123"
  }]
}
```

- `location` and a valid ISO 8601 `start_at` are required. Date-only values
  (`2026-10-06`) are supported when a time has not been announced.
- For UTC timestamps, supply the venue's IANA `time_zone`; the example above
  displays **October 6 at 21:00**, regardless of the listener's device time zone.
  Explicit offsets are also supported. Without a recognized time zone, the app
  preserves the wall-clock fields supplied in `start_at`.
- `id`, `venue`, and `url` are optional. The app deduplicates by event ID (or
  date/location/venue), orders events by date, and accepts at most 500 entries.
- Only HTTP(S) event links can be opened, and only after tapping an event.
- Providers should return upcoming events only. Failure to fetch this optional
  information must not fail the artist's albums or top tracks.

The badge opens a native schedule with artist identity, venue-local date tiles,
and event details. Labels are provider-neutral in both application themes.
Concert metadata is supplied with the artist response, so the schedule opens
immediately without a second loading state or network request.
