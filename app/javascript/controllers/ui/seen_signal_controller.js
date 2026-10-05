import { Controller } from "@hotwired/stimulus"

// A "something new" signal on a trigger (Ui::ChangelogComponent): the first click removes it and
// saves the key on the account, so it does not come back on any device.
export default class extends Controller {
  static targets = ["signal"]
  static values = { url: String, key: String }

  mark() {
    if (!this.hasSignalTarget) return

    this.signalTargets.forEach((signal) => signal.remove())
    const body = new FormData()
    body.append("key", this.keyValue)
    const csrf = document.querySelector("meta[name='csrf-token']")?.content
    fetch(this.urlValue, { method: "POST", body, headers: { "X-CSRF-Token": csrf } }).catch(() => {})
  }
}
