import { Controller } from "@hotwired/stimulus"

// Ui::FloatingNoticeComponent — closing hides the notice now and saves the choice on the account.
export default class extends Controller {
  static values = { url: String, key: String }

  dismiss() {
    this.element.remove()
    const body = new FormData()
    body.append("key", this.keyValue)
    fetch(this.urlValue, { method: "POST", body, headers: { "X-CSRF-Token": this.#csrf() } }).catch(() => {})
  }

  #csrf() {
    return document.querySelector("meta[name='csrf-token']")?.content
  }
}
