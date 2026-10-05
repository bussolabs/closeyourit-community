// Records the microphone as 16 kHz mono 16-bit WAV, the only format the gateway's Whisper accepts
// (verified 2026-10-01: webm, mp4, mp3, ogg and 48 kHz WAV are refused), and exposes the loudness
// that drives the waves. ScriptProcessorNode is deprecated but needs no separate worklet file (CYRA-908).
const TARGET_RATE = 16000
// Shared by the topbar overlay and the panel's microphone. A muted or wrong input device opens
// fine and just delivers zeros (Whisper then invents "you"), hence the silence check.
export const SILENCE_SECONDS = 3
export const HEARD_LEVEL = 0.02
// Remembered per browser: the device ids belong to this computer, not to the account.
const DEVICE_KEY = "cyi.voice.device"

export function savedDevice() {
  try { return localStorage.getItem(DEVICE_KEY) } catch (_error) { return null }
}

export function saveDevice(deviceId) {
  try {
    deviceId ? localStorage.setItem(DEVICE_KEY, deviceId) : localStorage.removeItem(DEVICE_KEY)
  } catch (_error) { /* storage blocked: the choice just lasts until the page closes */ }
}

export default class VoiceRecorder {
  // deviceId: a microphone picked in the overlay; none means the browser's default.
  async start(deviceId) {
    const audio = { channelCount: 1, echoCancellation: true, noiseSuppression: true }
    if (deviceId) audio.deviceId = { exact: deviceId }
    this.stream = await navigator.mediaDevices.getUserMedia({ audio })
    const Context = window.AudioContext || window.webkitAudioContext
    this.context = new Context()
    await this.context.resume()
    const source = this.context.createMediaStreamSource(this.stream)

    this.analyser = this.context.createAnalyser()
    this.analyser.fftSize = 512
    this.samples = new Uint8Array(this.analyser.fftSize)
    source.connect(this.analyser)

    this.chunks = []
    this.processor = this.context.createScriptProcessor(4096, 1, 1)
    this.processor.onaudioprocess = (event) => this.chunks.push(new Float32Array(event.inputBuffer.getChannelData(0)))
    const mute = this.context.createGain()
    mute.gain.value = 0
    source.connect(this.processor)
    this.processor.connect(mute)
    mute.connect(this.context.destination)
  }

  deviceId() {
    return this.stream?.getAudioTracks()[0]?.getSettings().deviceId
  }

  // Loudness in 0..1 from the waveform's RMS.
  level() {
    if (!this.analyser) return 0
    this.analyser.getByteTimeDomainData(this.samples)
    let sum = 0
    for (const sample of this.samples) { const v = (sample - 128) / 128; sum += v * v }
    return Math.min(1, Math.sqrt(sum / this.samples.length) * 5)
  }

  stop() {
    const rate = this.context?.sampleRate || TARGET_RATE
    const merged = merge(this.chunks || [])
    this.cancel()
    return encodeWav(downsample(merged, rate), TARGET_RATE)
  }

  cancel() {
    this.stream?.getTracks().forEach((track) => track.stop())
    this.processor?.disconnect()
    this.context?.close().catch(() => {})
    this.stream = this.context = this.processor = this.analyser = null
    this.chunks = []
  }
}

function merge(chunks) {
  const out = new Float32Array(chunks.reduce((total, chunk) => total + chunk.length, 0))
  let offset = 0
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.length }
  return out
}

// Averages each window of input samples into one output sample (a cheap low-pass + decimation).
function downsample(input, fromRate) {
  if (fromRate === TARGET_RATE) return input
  const ratio = fromRate / TARGET_RATE
  const out = new Float32Array(Math.floor(input.length / ratio))
  for (let i = 0; i < out.length; i++) {
    const start = Math.floor(i * ratio)
    const end = Math.min(input.length, Math.floor((i + 1) * ratio))
    let sum = 0
    for (let j = start; j < end; j++) sum += input[j]
    out[i] = sum / Math.max(1, end - start)
  }
  return out
}

function encodeWav(samples, rate) {
  const view = new DataView(new ArrayBuffer(44 + samples.length * 2))
  const text = (offset, value) => [...value].forEach((char, i) => view.setUint8(offset + i, char.charCodeAt(0)))
  text(0, "RIFF"); view.setUint32(4, 36 + samples.length * 2, true); text(8, "WAVE")
  text(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true)
  view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true)
  text(36, "data"); view.setUint32(40, samples.length * 2, true)
  samples.forEach((sample, i) => {
    const clamped = Math.max(-1, Math.min(1, sample))
    view.setInt16(44 + i * 2, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true)
  })
  return new Blob([view], { type: "audio/wav" })
}
