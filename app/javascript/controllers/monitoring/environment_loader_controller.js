import { Controller } from "@hotwired/stimulus"

// Ricarica il turbo-frame dell'Environment scoping-ato al progetto selezionato.
// Al `change` del select Project imposta `frame.src = new_monitor_path?project_id=X`:
// l'action `new` ri-renderizza il form e Turbo estrae solo il frame con gli environment di X.
export default class extends Controller {
  static values = { url: String, frame: String }

  reload(event) {
    const frame = document.getElementById(this.frameValue)
    if (!frame) return

    const url = new URL(this.urlValue, window.location.origin)
    const projectId = event.target.value
    if (projectId) url.searchParams.set("project_id", projectId)
    frame.src = url.toString()
  }
}
