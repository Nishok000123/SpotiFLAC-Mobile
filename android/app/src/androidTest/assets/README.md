# Synthetic DSD fixture

`dsd-pattern.wv` is original test data, not a music recording. WavPack 5.9.0
encoded a stereo DSD64 DSF with 16,384 bytes per channel and 4,096-byte channel
blocks. Normalized MSB-first byte `i` of channel `c` is `(i * 17 + c * 29) & 255`.
The DSF input stores those bytes with reversed bits (LSB-first).

This tests lossless WavPack DSD decoding, channel order, seek alignment, native
LE/BE packing and DoP packing against known bytes. It is packaged only in the
instrumentation test APK.
