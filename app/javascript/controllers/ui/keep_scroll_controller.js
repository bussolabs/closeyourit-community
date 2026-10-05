import { Controller } from "@hotwired/stimulus"

// A side index that scrolls on its own (Administration, Guides): every link opens a new page, which
// draws the index again from the top. The position is kept for the tab across those pages, and the
// open entry is brought into view when there is nothing to restore.
export default class extends Controller {
  static values = { key: String }

  connect() {
    const saved = this.#read()
    if (saved !== null) this.element.scrollTop = saved
    else this.element.querySelector("[aria-current='page']")?.scrollIntoView({ block: "nearest" })
  }

  // Saved while scrolling, not on disconnect: by then the old index has left the page and reads 0.
  save() {
    this.#write(this.element.scrollTop)
  }

  get #storageKey() {
    return `keep-scroll:${this.keyValue}`
  }

  // Storage can be missing or refused (private windows): the index then simply starts at the top.
  #read() {
    try {
      const value = sessionStorage.getItem(this.#storageKey)
      return value === null ? null : Number(value)
    } catch {
      return null
    }
  }

  #write(value) {
    try {
      sessionStorage.setItem(this.#storageKey, String(value))
    } catch {
      // Nothing to keep.
    }
  }
}
