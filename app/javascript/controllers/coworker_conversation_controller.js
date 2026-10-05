import { Controller } from "@hotwired/stimulus"

// CYRA-992 — the Coworkers conversation opens on the latest message and stays there while an answer
// streams in. Scrolling away shows the "latest message" button. An older page
// loads above without moving what the reader is looking at.
const NEAR = 40
const FAR = 120

export default class extends Controller {
  static targets = ["scroller", "jump", "day", "taskOpener", "taskForm"]

  connect() {
    this.dedupeDays()
    if (!this.anchoredRun()) this.toBottom()
    this.scrolled()
  }

  scrolled() {
    if (!this.hasScrollerTarget) return
    const distance = this.distanceFromBottom()
    if (this.hasJumpTarget) {
      this.jumpTarget.hidden = distance <= FAR
      this.jumpTarget.style.bottom = `${this.jumpTarget.nextElementSibling.offsetHeight + 12}px`
    }
  }

  jump() {
    this.scrollerTarget.scrollTo({ top: this.scrollerTarget.scrollHeight, behavior: "smooth" })
  }

  // A streamed answer grows the last bubble: follow it only if the reader was already at the bottom.
  // A task card replaced by the stream comes back closed: reopen the ones the reader had open.
  streamed(event) {
    const follow = this.hasScrollerTarget && this.distanceFromBottom() <= NEAR
    const open = [...this.element.querySelectorAll("[data-test=coworkers-task-card][open]")].map((card) => card.closest("article").id)
    const render = event.detail.render
    event.detail.render = async (stream) => {
      await render(stream)
      open.forEach((id) => document.getElementById(id)?.querySelector("details")?.setAttribute("open", ""))
      if (!this.hasScrollerTarget) return
      if (follow) this.toBottom()
      this.scrolled()
    }
  }

  holdPosition() {
    this.fromBottom = this.scrollerTarget.scrollHeight - this.scrollerTarget.scrollTop
  }

  restorePosition() {
    this.dedupeDays()
    this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight - this.fromBottom
  }

  openTask() {
    this.taskOpenerTarget.hidden = true
    this.taskFormTarget.hidden = false
    this.taskFormTarget.querySelector("textarea")?.focus()
  }

  // Every page starts with its day line: when an older page ends on the same day, drop the repeat.
  dedupeDays() {
    let previous = null
    this.dayTargets.forEach((day) => {
      const label = day.textContent.trim()
      if (label === previous) day.remove()
      previous = label
    })
  }

  anchoredRun() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    if (!id.startsWith("coworker_task_progress_")) return false
    const target = document.getElementById(id)
    target?.scrollIntoView({ block: "center" })
    return Boolean(target)
  }

  toBottom() {
    this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
  }

  distanceFromBottom() {
    const scroller = this.scrollerTarget
    return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop
  }
}
