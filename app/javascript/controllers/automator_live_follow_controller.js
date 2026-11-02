import { Controller } from "@hotwired/stimulus"

// CYRA-1138 — while the live page follows the agent, its newest change is brought into view each time the
// frame reloads. Only the code panel scrolls ("nearest"), so the page around it stays where it is.
export default class extends Controller {
  connect() {
    this.element.scrollIntoView({ block: "nearest", behavior: "auto" })
  }
}
