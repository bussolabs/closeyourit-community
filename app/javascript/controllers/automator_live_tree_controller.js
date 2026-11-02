import { Controller } from "@hotwired/stimulus"

// The folders a viewer opens in the live project tree stay open when the live signal reloads the page frame.
// Kept in memory for this tab only: a new visit starts from the folders the agent works in.
const opened = new Set()

export default class extends Controller {
  static targets = ["folder"]

  folderTargetConnected(folder) {
    if (opened.has(folder.dataset.dir)) folder.open = true
  }

  remember(event) {
    const folder = event.currentTarget
    folder.open ? opened.add(folder.dataset.dir) : opened.delete(folder.dataset.dir)
  }
}
