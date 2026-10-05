import { Controller } from "@hotwired/stimulus"

// CYRA-901 — the list's results live in a turbo-frame that advances the URL, while this switch sits
// outside it and is never re-rendered: its server-built hrefs would carry the filters of the first
// load. On click, rebuild the link from the address as it is now. Without JS the server href stays.
export default class extends Controller {
  static values = { keys: Array, marker: String }

  follow(event) {
    const link = event.currentTarget
    const current = new URLSearchParams(window.location.search)
    const carried = new URLSearchParams()
    current.forEach((value, name) => {
      if (value !== "" && this.keysValue.includes(name.replace(/\[\]$/, ""))) carried.append(name, value)
    })
    carried.set(this.markerValue, "1")
    const url = new URL(link.href, window.location.origin)
    url.search = carried.toString()
    link.href = url.toString()
  }
}
