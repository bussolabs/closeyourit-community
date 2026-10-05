import { Controller } from "@hotwired/stimulus"

// CYRA-933 — every New opens in one modal over the page.
//
// A link to a ".../new" page is pointed at the "modal" frame, which this controller builds inside the
// <dialog> (the server never sends it: a full page that carried it would satisfy the frame, and a
// save could never leave the modal). The server answers that frame with the form alone; a save
// redirects to a full page, the frame is missing from it, and the browser visits that page.
// Without JS the link stays a plain link to the /new page.
//
// The stacked instance (stack value) opens a second modal on top for a link marked data-modal-stack
// inside the open modal: the + next to a select. Its save answers [data-modal-created], which is
// added to that select underneath and picked, and the stacked modal closes.
//
// What is typed is kept as a draft per New (localStorage): a modal closed by mistake reopens with it.
// A save that leaves the modal, or Cancel, drops the draft. Drafts are keyed by account and
// organization (scope value): on a shared browser one person's draft never opens for another.
const sizes = new Map()

export default class extends Controller {
  static values = { loading: String, stack: Boolean, scope: String }

  connect() {
    this.dropUnscopedDrafts()
    this.frame = document.createElement("turbo-frame")
    this.frame.id = this.stackValue ? "modal_stack" : "modal"
    this.element.replaceChildren(this.frame)
    this.route = this.route.bind(this)
    this.opened = this.opened.bind(this)
    this.missing = this.missing.bind(this)
    this.saveDraft = this.saveDraft.bind(this)
    this.prefetch = this.prefetch.bind(this)
    document.addEventListener("click", this.route, true)
    document.addEventListener("turbo:before-prefetch", this.prefetch, true)
    this.frame.addEventListener("input", this.saveDraft)
    this.frame.addEventListener("change", this.saveDraft)
    this.frame.addEventListener("turbo:submit-start", () => { this.submitting = true })
    // Turbo inserts the form before its render event: keep it unavailable until drafts are ready.
    this.frame.addEventListener("turbo:before-frame-render", (event) => {
      if (event.target === this.frame) this.frame.style.visibility = "hidden"
    })
    // On render: the form is in, whether the answer was fetched now or prefetched on hover.
    this.frame.addEventListener("turbo:frame-render", this.opened)
    this.frame.addEventListener("turbo:frame-missing", this.missing)
  }

  disconnect() {
    clearTimeout(this.restoreTimer)
    document.removeEventListener("click", this.route, true)
    document.removeEventListener("turbo:before-prefetch", this.prefetch, true)
  }

  route(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const link = event.target.closest("a[href]")
    if (!link || link.target || link.hasAttribute("download") || link.dataset.turbo === "false") return

    // The header actions of the form in the modal (Cancel) just close it: the page is behind.
    if (this.element.contains(link) && link.closest("[data-test$='actions']")) {
      event.preventDefault()
      this.dropDraft()
      this.element.close()
      return
    }
    const url = this.claim(link)
    if (!url) return

    if (this.stackValue) this.pickInto = link.closest("dialog").querySelector(`select[name="${link.dataset.modalStack}"]`)
    this.draftKey = `member-modal-draft:${this.scopeValue}:${url.pathname}${url.search}`
    this.showLoading()
  }

  // Turbo prefetches a link on hover: unmarked, it would fetch the full page and the click would
  // then be served that page instead of the form for the modal.
  prefetch(event) {
    const link = event.target.closest?.("a[href]")
    if (link && !link.target && link.dataset.turbo !== "false") this.claim(link)
  }

  // Points a New link at this modal's frame; returns its URL, or null when the link is not ours.
  claim(link) {
    if (link.hasAttribute("data-action")) return null
    if (link.dataset.turboFrame && link.dataset.turboFrame !== this.frame.id) return null
    if (this.element.contains(link) && link.closest("[data-test$='actions']")) return null

    const stacked = link.dataset.modalStack !== undefined && !!link.closest("dialog[open]")
    if (stacked !== this.stackValue) return null

    // /member/new is Quick add, a page of choices rather than a form.
    const url = new URL(link.href, location.href)
    const form = /\/new\/?$/.test(url.pathname) && url.pathname !== "/member/new"
    if (url.origin !== location.origin || !form) return null

    link.dataset.turboFrame = this.frame.id
    return url
  }

  // The form can take a few seconds: the modal opens at once and says it is on its way.
  showLoading() {
    clearTimeout(this.restoreTimer)
    this.frame.style.visibility = ""
    this.drafting = false
    // A save that never came back (network error) must not stop this New from restoring its draft.
    this.submitting = false
    // The size this New had last time, so a wide form does not open small and then grow.
    this.element.dataset.size = sizes.get(this.draftKey) || ""
    const note = document.createElement("p")
    note.className = "px-5 py-10 text-center text-[12.5px] text-gray-500 dark:text-zinc-400"
    note.setAttribute("role", "status")
    note.dataset.test = "member-modal-loading"
    note.textContent = this.loadingValue
    this.frame.replaceChildren(note)
    if (!this.element.open) this.element.showModal()
  }

  opened(event) {
    if (event.target !== this.frame) return
    // A load that lands after the modal was closed (and emptied) must not open it again.
    if (!this.frame.getAttribute("src")) return
    const created = this.frame.querySelector("[data-modal-created]")
    if (created) {
      this.dropDraft()
      return this.pick(created)
    }
    // A failed save comes back with what was sent: the draft would only repeat it.
    // After the form's own controllers have connected: they set their fields up on connect.
    const restore = !this.submitting
    this.submitting = false
    clearTimeout(this.restoreTimer)
    this.restoreTimer = setTimeout(() => {
      if (!this.element.open || !this.frame.getAttribute("src")) return
      if (restore) this.restoreDraft()
      this.drafting = true
      this.frame.style.visibility = ""
    })
    this.element.dataset.size = this.frame.querySelector("[data-modal-size]")?.dataset.modalSize || ""
    sizes.set(this.draftKey, this.element.dataset.size)
    if (!this.element.open) this.element.showModal()
  }

  draftFields() {
    const skip = ["file", "hidden", "password", "submit", "button", "reset"]
    return [...this.frame.querySelectorAll("form [name]")].filter((field) =>
      field.name !== "authenticity_token" && !skip.includes(field.type) && field.matches("input, textarea, select"))
  }

  // Only once the form is in and restored: its own controllers fire change while it loads, and
  // saving then would overwrite the draft with an empty form.
  saveDraft() {
    if (!this.draftKey || !this.drafting) return
    const values = this.draftFields().map((field) => {
      if (field.type === "checkbox" || field.type === "radio") return [field.name, field.value, field.checked]
      if (field.multiple) return [field.name, [...field.selectedOptions].map((option) => option.value)]
      return [field.name, field.value]
    })
    try { localStorage.setItem(this.draftKey, JSON.stringify(values)) } catch {}
  }

  restoreDraft() {
    let values
    try { values = JSON.parse(localStorage.getItem(this.draftKey) || "null") } catch { values = null }
    if (!Array.isArray(values)) return

    this.restoreRows(values)
    const fields = this.draftFields()
    values.forEach(([name, value, checked]) => {
      const matches = fields.filter((field) => field.name === name)
      matches.forEach((field) => {
        if (field.type === "checkbox" || field.type === "radio") {
          if (field.value === value) field.checked = checked
        } else if (field.multiple) {
          [...field.options].forEach((option) => { option.selected = value.includes(option.value) })
        } else {
          field.value = value
        }
      })
    })
    // change too: the form's controllers (milestones, parents, platforms) refresh on it.
    fields.forEach((field) => {
      field.dispatchEvent(new Event("input", { bubbles: true }))
      field.dispatchEvent(new Event("change", { bubbles: true }))
      if (field.tagName === "SELECT") field.dispatchEvent(new CustomEvent("ui--select:refresh"))
    })
  }

  // Rows added by hand (scenarios, conditions) are not in the form the server sends: rebuild each one
  // from its nested-fields template, with the index the draft saved, before the values go in.
  restoreRows(values) {
    const present = new Set(this.draftFields().map((field) => field.name))
    this.frame.querySelectorAll("template[data-nested-fields-target='template']").forEach((template) => {
      const prefix = template.innerHTML.match(/name="([^"]*?)NEW_RECORD/)?.[1]
      const owner = template.closest("[data-controller~='nested-fields']")
      const container = owner && [...owner.querySelectorAll("[data-nested-fields-target='container']")]
        .find((element) => element.closest("[data-controller~='nested-fields']") === owner)
      if (!prefix || !container) return

      const indexes = new Set()
      values.forEach(([name]) => {
        const index = !present.has(name) && name.startsWith(prefix) && name.slice(prefix.length).match(/^(\d+)\]/)?.[1]
        if (index) indexes.add(index)
      })
      indexes.forEach((index) => {
        const html = template.innerHTML.replaceAll("NEW_RECORD", index)
        const row = document.createRange().createContextualFragment(html).firstElementChild
        if (row) container.appendChild(row)
      })
    })
  }

  // Drafts saved before they were keyed by account: nobody can tell whose they are.
  dropUnscopedDrafts() {
    try {
      Object.keys(localStorage).filter((key) => key.startsWith("member-modal-draft:/"))
        .forEach((key) => localStorage.removeItem(key))
    } catch {}
  }

  dropDraft() {
    if (!this.draftKey) return
    try { localStorage.removeItem(this.draftKey) } catch {}
  }

  // The stacked save created a record: add it to the select underneath, pick it, close this modal.
  pick(created) {
    const select = this.pickInto
    if (select) {
      const { value, label, color } = created.dataset
      if (![...select.options].some((option) => option.value === value)) {
        const option = new Option(label, value)
        if (color) option.dataset.color = color
        select.add(option)
      }
      select.value = value
      select.dispatchEvent(new Event("change", { bubbles: true }))
      select.dispatchEvent(new CustomEvent("ui--select:refresh"))
    }
    this.element.close()
  }

  missing(event) {
    event.preventDefault()
    this.dropDraft()
    this.element.close()
    event.detail.visit(event.detail.response)
  }

  backdrop(event) {
    if (event.target === this.element) this.element.close()
  }

  // Empty on close, so the same New opens fresh next time instead of keeping a half-filled form.
  reset() {
    // The close event is queued: a New opened again meanwhile already owns the modal.
    if (this.element.open) return
    clearTimeout(this.restoreTimer)
    this.frame.removeAttribute("src")
    this.frame.replaceChildren()
    delete this.element.dataset.size
    this.drafting = false
  }
}
