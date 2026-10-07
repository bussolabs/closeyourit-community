import { Controller } from "@hotwired/stimulus"

// A spoken conversation with a Puck (CYRA-1021): the microphone listens, what was said is sent as a
// message, the Puck's answer is read aloud with the browser's voice, then the microphone listens
// again. Everything stays written in the conversation. Ends with the same button.
export default class extends Controller {
  static targets = ["toggle", "status"]
  static values = { labels: Object, lang: String }

  connect() {
    this.active = false
    this.spoken = new Set(this.answers().map(node => node.dataset.coworkerRunId))
    this.observer = new MutationObserver(() => this.listenForAnswer())
    this.toggleTarget.hidden = !("speechSynthesis" in window)
  }

  disconnect() {
    this.stop()
  }

  toggle() {
    this.active ? this.stop() : this.start()
  }

  start() {
    this.active = true
    this.toggleTarget.setAttribute("aria-pressed", "true")
    this.observer.observe(document.querySelector("[data-test='coworkers-conversation']") || this.element, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-status"] })
    this.say(this.labelsValue.started)
    this.listen()
  }

  stop() {
    this.active = false
    this.toggleTarget?.setAttribute("aria-pressed", "false")
    this.observer?.disconnect()
    window.speechSynthesis?.cancel()
    this.status("")
  }

  // Bound to the dictation's "dictated" event: in a call, what was said goes out at once.
  dictated() {
    if (!this.active) return
    this.status(this.labelsValue.thinking)
    this.element.requestSubmit()
  }

  listenForAnswer() {
    const done = this.answers().find(node => ["completed", "failed", "stopped", "interrupted"].includes(node.dataset.status) &&
                                             !this.spoken.has(node.dataset.coworkerRunId))
    if (!done) return
    this.spoken.add(done.dataset.coworkerRunId)
    const text = done.querySelector("[data-test='coworkers-output']")?.innerText || this.labelsValue.noAnswer
    this.say(text, () => this.listen())
  }

  answers() {
    return Array.from(document.querySelectorAll("[data-test='coworkers-run'][data-coworker-kind='chat']"))
  }

  say(text, then) {
    const utterance = new SpeechSynthesisUtterance(text.slice(0, 1500))
    utterance.lang = this.langValue
    utterance.onend = () => { if (this.active && then) then() }
    this.status(this.labelsValue.speaking)
    window.speechSynthesis.cancel()
    window.speechSynthesis.speak(utterance)
  }

  listen() {
    if (!this.active) return
    this.status(this.labelsValue.listening)
    this.element.querySelector("[data-test='dictation-mic']")?.click()
  }

  status(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
