import { Controller } from "@hotwired/stimulus"

// SOLO development: prefill di email/password dal <select> personas nella pagina di login.
export default class extends Controller {
  static targets = ["email", "password"]

  fill(event) {
    const option = event.target.selectedOptions[0]
    if (!option || !option.value) return

    if (this.hasEmailTarget) this.emailTarget.value = option.value
    if (this.hasPasswordTarget) this.passwordTarget.value = option.dataset.password || ""
  }
}
