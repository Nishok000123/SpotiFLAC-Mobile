use crate::cancellation::RequestLease;
use crate::tags::{check_lease, open_audio_file};
use spotiflac_core::media::hires::{self, HiResCheckOptions};
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum HiResCheckError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<String> for HiResCheckError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

/// Runs the fake Hi-Res check on one local FLAC or WAV file; `options_json`
/// may be empty or override any `HiResCheckOptions` field. A format the
/// checker cannot decode is not an error: it returns `{"supported": false}`
/// so the UI can say "not checkable" rather than report a broken file.
/// CPU-bound for a second or two: call it off the main thread.
#[uniffi::export]
pub fn check_hires_authenticity(
    path: String,
    options_json: String,
    lease: Option<Arc<RequestLease>>,
) -> Result<String, HiResCheckError> {
    let options: HiResCheckOptions = if options_json.trim().is_empty() {
        HiResCheckOptions::default()
    } else {
        serde_json::from_str(&options_json)
            .map_err(|error| format!("invalid hi-res check options: {error}"))?
    };
    let check = || check_lease(lease.as_deref());
    check()?;
    let file = open_audio_file(&path)?;
    let result = match hires::check_file(file, &path, &options, &check) {
        Ok(result) => result,
        Err(hires::HiResCheckError::Unsupported) => {
            return Ok(serde_json::json!({"supported": false, "file_path": path}).to_string());
        }
        Err(error) => return Err(error.to_string().into()),
    };
    let mut value = serde_json::to_value(&result).map_err(|error| error.to_string())?;
    if let Some(object) = value.as_object_mut() {
        object.insert("supported".into(), true.into());
        object.insert("is_suspicious".into(), result.is_suspicious().into());
        object.insert("padded_bit_depth".into(), result.padded_bit_depth().into());
        object.insert("redownload_safe".into(), result.redownload_safe().into());
    }
    Ok(value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_formats_are_not_errors_and_bad_options_are() {
        let dir =
            std::env::temp_dir().join(format!("spotiflac-hires-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let mp3 = dir.join("song.mp3");
        std::fs::write(&mp3, b"ID3\x04\x00\x00\x00\x00\x00\x00junk").expect("write");
        let path = mp3.to_string_lossy().to_string();

        let raw = check_hires_authenticity(path.clone(), String::new(), None).expect("check");
        let value: serde_json::Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(value["supported"], false);

        assert!(check_hires_authenticity(path, "{bad".into(), None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
