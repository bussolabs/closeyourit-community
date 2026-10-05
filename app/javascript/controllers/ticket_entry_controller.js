import { Controller } from "@hotwired/stimulus"

// New ticket has more than one way in (by hand, drafted by the assistant): the tabs of its header
// show one panel at a time. Without JS every panel is on the page and the tabs are plain anchors.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { active: String, inactive: String }

  connect() {
    this.show(0)
  }

  select(event) {
    this.show(Number(event.params.index))
  }

  showFirst() {
    this.show(0)
  }

  show(index) {
    this.panelTargets.forEach((panel, i) => { panel.hidden = i !== index })
    this.tabTargets.forEach((tab, i) => {
      tab.className = i === index ? this.activeValue : this.inactiveValue
      if (i === index) tab.setAttribute("aria-current", "page")
      else tab.removeAttribute("aria-current")
    })
  }
}
