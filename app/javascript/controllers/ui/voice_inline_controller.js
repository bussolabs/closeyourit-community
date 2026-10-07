import { Controller } from "@hotwired/stimulus"
import VoiceRecorder, { SILENCE_SECONDS, HEARD_LEVEL, savedDevice, saveDevice } from "controllers/ui/voice_recorder"
import { drawWaves } from "controllers/ui/voice_waves"

// Microphone of the assistant panel's composer: while recording, the waves take the text field's
// place and the send button sends the audio to the conversation on screen (panel or conversation
// page; the bubble arrives by broadcast). The microphone picked
// in the topbar overlay is reused (CYRA-908).
//
// With `dictate` it serves a plain text field instead: the field stays in view, a Done button stops
// the recording, and the text that comes back is added to the field — nothing is sent anywhere.
export default class extends Controller {
  static targets = ["input", "waves", "canvas", "status", "mic", "cancel", "done"]
  static values = { url: String, maxSeconds: Number, labels: Object, openPanel: { type: Boolean, default: true },
                    dictate: { type: Boolean, default: false } }

  connect() {
    const supported = navigator.mediaDevices?.getUserMedia && (window.AudioContext || window.webkitAudioContext)
    this.micTarget.hidden = !supported
    // Capture phase: while recording, Esc cancels the recording instead of closing the panel.
    this._onKeydown = (event) => {
      if (event.key !== "Escape" || this.wavesTarget.hidden) return
      event.stopPropagation()
      event.preventDefault() // inside a <dialog>, Esc would otherwise close the dialog too
      this.cancel()
    }
    document.addEventListener("keydown", this._onKeydown, true)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown, true)
    this.recorder?.cancel()
    this._finish()
  }

  // On mousedown: the button must not take the focus, or a field that grows on focus would move
  // it from under the pointer before the click lands.
  hold(event) {
    event.preventDefault()
  }

  async start() {
    if (this.dictateValue) this.inputTarget.focus()
    this.recording = true
    this.seconds = 0
    this.heard = false
    this.level = 0
    this.phase = 0
    this._toggle(true)
    this._status(this._time())
    this._animate()
    if (!(await this._record(savedDevice()))) return
    this.timer = setInterval(() => this._tick(), 1000)
  }

  // Bound to the send button: a plain click while typing, the audio while recording.
  async send(event) {
    if (!this.recording || !this.recorder) return
    event?.preventDefault()
    this.recording = false
    clearInterval(this.timer)
    const wav = this.recorder.stop()
    this.recorder = null
    this._status(this.labelsValue.sending)

    const body = new FormData()
    body.append("audio", wav, "voice.wav")
    // Cancel while the text is on its way aborts it: a late answer must not land in the field.
    const request = this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", body, credentials: "same-origin", signal: request.signal,
        headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" }
      })
      if (!response.ok) return this._problem(await response.text() || this.labelsValue.failed)
      const text = this.dictateValue ? (await response.json()).text : null
      if (request.signal.aborted) return
      if (this.dictateValue) this._write(text)
    } catch (_error) {
      if (request.signal.aborted) return
      return this._problem(this.labelsValue.failed)
    } finally {
      if (this.request === request) this.request = null
    }
    this._finish()
    if (this.openPanelValue) window.dispatchEvent(new CustomEvent("assistant:open"))
  }

  cancel() {
    this.request?.abort()
    this.recorder?.cancel()
    this._finish()
  }

  // --- internals ---

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
      this._problem(error?.name === "NotAllowedError" ? this.labelsValue.denied : this.labelsValue.failed)
      return false
    }
    if (!this.recording || this.recorder !== recorder) {
      recorder.cancel()
      return false
    }
    return true
  }

  _tick() {
    this.seconds += 1
    this._status(this.heard || this.seconds < SILENCE_SECONDS ? this._time() : this.labelsValue.silent,
                 { silent: !this.heard && this.seconds >= SILENCE_SECONDS })
    if (this.seconds >= this.maxSecondsValue) this.send()
  }

  _time() {
    return `${Math.floor(this.seconds / 60)}:${String(this.seconds % 60).padStart(2, "0")}`
  }

  _animate() {
    cancelAnimationFrame(this.frame)
    const step = () => {
      this.frame = requestAnimationFrame(step)
      const target = this.recording ? (this.recorder?.level() || 0) : 0
      if (!this.heard && target > HEARD_LEVEL) {
        this.heard = true
        this._status(this._time())
      }
      this.level += (target - this.level) * (target > this.level ? 0.35 : 0.08)
      this.phase += 1
      const canvas = this.canvasTarget
      drawWaves(canvas, this.level, this.phase, { width: canvas.clientWidth, height: canvas.clientHeight })
    }
    step()
  }

  // Adds the dictated text after what the field already holds; `input` lets drafts and counters follow.
  _write(text) {
    const field = this.inputTarget
    field.value = [field.value.trimEnd(), text].filter(Boolean).join(field.value.trim() ? " " : "")
    field.dispatchEvent(new Event("input", { bubbles: true }))
    // A Puck call sends what was said as soon as it is written (CYRA-1021).
    this.dispatch("dictated", { detail: { text } })
  }

  // The strip stays up with the reason; the cancel button gives the text field back.
  _problem(text) {
    this.recording = false
    clearInterval(this.timer)
    this.recorder?.cancel()
    this.recorder = null
    this._status(text, { silent: true })
  }

  _status(text, { silent = false } = {}) {
    this.statusTarget.textContent = text
    this.statusTarget.toggleAttribute("data-silent", silent)
  }

  _toggle(recording) {
    if (!this.dictateValue) this.inputTarget.hidden = recording
    if (this.hasDoneTarget) this.doneTarget.hidden = !recording
    this.wavesTarget.hidden = !recording
    this.micTarget.hidden = recording
    this.cancelTarget.hidden = !recording
  }

  _finish() {
    this.recording = false
    clearInterval(this.timer)
    cancelAnimationFrame(this.frame)
    this.recorder = null
    this._toggle(false)
    // An empty dictation field goes back to rest; otherwise the caret returns to the text.
    if (this.dictateValue && !this.inputTarget.value) this.inputTarget.blur()
    else this.inputTarget.focus()
  }
}
