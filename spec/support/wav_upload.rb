# frozen_string_literal: true

# A tiny 16 kHz mono 16-bit WAV as an upload: the only format the gateway's Whisper accepts. CYRA-908
module WavUpload
  def wav_bytes(samples: 1600)
    data = ([ 0 ] * samples).pack("s<*")
    header = [ "RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, 16_000, 32_000, 2, 16, "data", data.bytesize ]
             .pack("A4VA4A4VvvVVvvA4V")
    header + data
  end

  def wav_upload(bytes: wav_bytes, content_type: "audio/wav")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, true, original_filename: "voice.wav")
  end
end

RSpec.configure { |config| config.include WavUpload }
