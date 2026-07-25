ALTER TABLE device_audio_uploads ADD COLUMN storage_key TEXT;
CREATE UNIQUE INDEX device_audio_uploads_range
  ON device_audio_uploads(device_id, start_seq, packet_count);
