import { Controller } from "@hotwired/stimulus"

// CYRA-521/582 — keeps ONE sidebar group open and remembers which. The group holding the open page
// always wins over the memory. CYRA-903: a group is no longer a <details>; its chevron is a button
// with aria-expanded, because the group name became the link to the area's overview.
//
// The memory is a preference of this browser, not organization data: localStorage, no round trip.
export default class extends Controller {
  static targets = ["group", "toggle"]

  // Still the old key and plural: renaming it would drop the preference people already have.
  static STORAGE_KEY = "closeyourit:nav-groups-aperti"

  connect() {
    const active = this.groupTargets.find((group) => this.#isOpen(group))

    this.#openOnly(active ? this.#id(active) : this.#read())
  }

  toggle(event) {
    const group = this.groupTargets.find((candidate) => candidate.contains(event.currentTarget))
    if (!group) return

    this.#openOnly(this.#isOpen(group) ? null : this.#id(group))
    this.#save()
  }

  #openOnly(id) {
    this.groupTargets.forEach((group) => this.#setOpen(group, this.#id(group) === id))
  }

  #setOpen(group, open) {
    const toggle = this.#toggleOf(group)
    const items = toggle && document.getElementById(toggle.getAttribute("aria-controls"))
    if (!toggle || !items) return

    toggle.setAttribute("aria-expanded", String(open))
    items.hidden = !open
  }

  #isOpen(group) {
    return this.#toggleOf(group)?.getAttribute("aria-expanded") === "true"
  }

  #toggleOf(group) {
    return this.toggleTargets.find((toggle) => group.contains(toggle))
  }

  #save() {
    const open = this.groupTargets.find((group) => this.#isOpen(group))

    try {
      if (open) localStorage.setItem(this.constructor.STORAGE_KEY, JSON.stringify(this.#id(open)))
      // Last group closed: forget it, so the next page keeps the menu closed as just asked.
      else localStorage.removeItem(this.constructor.STORAGE_KEY)
    } catch {
      // Full quota or blocked storage: the sidebar still works, it just does not remember.
    }
  }

  #read() {
    try {
      const saved = JSON.parse(localStorage.getItem(this.constructor.STORAGE_KEY))

      // Before CYRA-582 the value was the LIST of open groups: reopen the first one only.
      return Array.isArray(saved) ? saved[0] : saved
    } catch {
      return null
    }
  }

  #id(group) {
    return group.dataset.navGroupId
  }
}
