import { Controller } from "@hotwired/stimulus"
import VoiceRecorder, { SILENCE_SECONDS, HEARD_LEVEL, savedDevice, saveDevice } from "controllers/ui/voice_recorder"
import { drawWaves } from "controllers/ui/voice_waves"

// Microphone of the topbar: blurred overlay with waves that follow the voice, a timer, Send /
// Cancel, Esc to cancel, automatic send at the time cap. The WAV goes to the voice endpoint and
// the assistant widget opens on the bubble (CYRA-908).
export default class extends Controller {
  static targets = ["trigger", "overlay", "canvas", "title", "hint", "recordingActions", "closeActions", "devices"]
  static values = { url: String, maxSeconds: Number, labels: Object }

  connect() {
    const supported = navigator.mediaDevices?.getUserMedia && (window.AudioContext || window.webkitAudioContext)
    this.triggerTarget.hidden = !supported
    // defaultPrevented: Esc inside the open microphone list closes the list, not the overlay.
    this._onKeydown = (event) => {
      if (event.key === "Escape" && !event.defaultPrevented && !this.overlayTarget.hidden) this.cancel()
    }
    document.addEventListener("keydown", this._onKeydown)
    this.deviceSelect.addEventListener("change", () => this.switchDevice())
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
    this.recorder?.cancel()
    this._stop()
  }

  async start() {
    this.state = "listening"
    this.seconds = 0
    this.level = 0
    this.phase = 0
    this.heard = false
    this.devicesTarget.hidden = true
    this._show(this._listeningTitle(), this.labelsValue.hint, { recording: true })
    this._animate()
    if (!(await this._record(savedDevice()))) return
    this.timer = setInterval(() => this._tick(), 1000)
  }

  async switchDevice() {
    const deviceId = this.deviceSelect.value
    if (this.state !== "listening" || !deviceId || deviceId === this.recorder?.deviceId()) return
    saveDevice(deviceId)
    this.recorder?.cancel()
    this.seconds = 0
    this.heard = false
    this.titleTarget.textContent = this._listeningTitle()
    this._hint(this.labelsValue.hint)
    await this._record(deviceId)
  }

  async send() {
    if (this.state !== "listening" || !this.recorder) return
    this.state = "sending"
    clearInterval(this.timer)
    const wav = this.recorder.stop()
    this._show(this.labelsValue.sending, "", { recording: false })

    const body = new FormData()
    body.append("audio", wav, "voice.wav")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", body, credentials: "same-origin",
        headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" }
      })
      if (!response.ok) return this._problem("failed", await response.text())
    } catch (_error) {
      return this._problem("failed")
    }
    this._stop()
    window.dispatchEvent(new CustomEvent("assistant:open"))
  }

  cancel() {
    this.recorder?.cancel()
    this._stop()
  }

  // --- internals ---

  // Opens the microphone (falling back to the default one when a remembered device is gone) and
  // fills the device list. Returns false when the overlay switched to a problem or was closed.
  async _record(deviceId) {
    const recorder = new VoiceRecorder()
    this.recorder = recorder
    try {
      await recorder.start(deviceId)
    } catch (error) {
      recorder.cancel()
      if (deviceId && ["OverconstrainedError", "NotFoundError"].includes(error?.name)) {
        saveDevice(null)
        return this._record(null)
      }
      this._problem(error?.name === "NotAllowedError" ? "denied" : "failed")
      return false
    }
    if (this.state !== "listening" || this.recorder !== recorder) {
      recorder.cancel()
      return false
    }
    await this._listDevices(recorder.deviceId())
    return true
  }

  // Device names are only readable once the permission is granted, so the list fills here.
  async _listDevices(current) {
    const devices = await navigator.mediaDevices.enumerateDevices().catch(() => [])
    const inputs = devices.filter((device) => device.kind === "audioinput")
    this.deviceSelect.replaceChildren(...inputs.map((device, index) => new Option(
      device.label || this.labelsValue.device_unnamed.replace("%{n}", index + 1),
      device.deviceId, false, device.deviceId === current
    )))
    this.deviceSelect.dispatchEvent(new Event("ui--select:refresh"))
    this.devicesTarget.hidden = inputs.length < 2
  }

  get deviceSelect() {
    return this.devicesTarget.querySelector("select")
  }


  _tick() {
    this.seconds += 1
    this.titleTarget.textContent = this._listeningTitle()
    if (!this.heard && this.seconds >= SILENCE_SECONDS) this._hint(this.labelsValue.silent_hint, { silent: true })
    if (this.seconds >= this.maxSecondsValue) this.send()
  }

  _listeningTitle() {
    const minutes = Math.floor(this.seconds / 60)
    const seconds = String(this.seconds % 60).padStart(2, "0")
    return this.labelsValue.listening.replace("%{time}", `${minutes}:${seconds}`)
  }

  _animate() {
    cancelAnimationFrame(this.frame)
    const step = () => {
      this.frame = requestAnimationFrame(step)
      const target = this.state === "listening" ? (this.recorder?.level() || 0) : 0
      if (!this.heard && target > HEARD_LEVEL) {
        this.heard = true
        this._hint(this.labelsValue.hint)
      }
      this.level += (target - this.level) * (target > this.level ? 0.35 : 0.08)
      this.phase += 1
      drawWaves(this.canvasTarget, this.level, this.phase)
    }
    step()
  }

  _problem(kind, detail) {
    this.state = kind
    clearInterval(this.timer)
    const title = kind === "denied" ? this.labelsValue.denied_title : this.labelsValue.failed_title
    const hint = kind === "denied" ? this.labelsValue.denied_hint : (detail || "")
    this._show(title, hint, { recording: false, closable: true })
  }

  _show(title, hint, { recording, closable = false }) {
    this.overlayTarget.hidden = false
    this.titleTarget.textContent = title
    this._hint(hint)
    this.recordingActionsTarget.hidden = !recording
    if (!recording) this.devicesTarget.hidden = true
    this.closeActionsTarget.hidden = !closable
  }

  _hint(text, { silent = false } = {}) {
    this.hintTarget.textContent = text
    this.hintTarget.toggleAttribute("data-silent", silent)
  }

  _stop() {
    this.state = null
    clearInterval(this.timer)
    cancelAnimationFrame(this.frame)
    this.recorder = null
    this.overlayTarget.hidden = true
  }
}
