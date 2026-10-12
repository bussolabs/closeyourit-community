import { Controller } from "@hotwired/stimulus"

// Map tab of a project (CYRA-1071): draws one level of blueprint.json at a time and fills the detail
// panel from the templates in the view. Click selects, double click opens a bubble. Edges deeper than
// the open level are lifted to the bubble that contains each end; an end outside the view becomes a
// dashed "ghost" at the branch where it leaves the open level.

// Canvas colours cannot be Tailwind classes: these are the hex values of the classes DESIGN.md names.
const PALETTE = {
  light: { ink: "#18181b", muted: "#6b7280", faint: "#9ca3af", surface: "#ffffff", subtle: "#fafaf9", border: "#d6d3d1", accent: "#4f46e5", accentSoft: "#eef2ff", accentInk: "#4338ca" },
  dark: { ink: "#f4f4f5", muted: "#a1a1aa", faint: "#71717a", surface: "#18181b", subtle: "#09090b", border: "#3f3f46", accent: "#818cf8", accentSoft: "#1e1b4b", accentInk: "#a5b4fc" }
}
const MAX_ROWS = 12
const DENSE_EDGES = 60
const START = "rails"

export default class extends Controller {
  static targets = ["canvas", "detail", "path", "search", "hits", "detailTemplate", "fileTemplate", "rowTemplate", "hitTemplate", "crumbTemplate"]
  static values = { map: Object, labels: Object }

  async connect() {
    const nodes = this.mapValue.nodes || []
    this.edges = this.mapValue.edges || []
    this.byId = Object.fromEntries(nodes.map((node) => [node.id, node]))
    this.children = {}
    nodes.forEach((node) => (this.children[node.parent] ||= []).push(node))
    this.focus = this.byId[START] ? START : null
    this.selected = null

    const { default: cytoscape } = await import("cytoscape")
    this.cy = cytoscape({ container: this.canvasTarget, style: this.#style(), minZoom: 0.3, maxZoom: 2.5, wheelSensitivity: 0.3 })
    this.cy.on("tap", "node", (event) => this.#tap(event.target))
    this.cy.on("dbltap", "node", (event) => this.#open(event.target.id()))
    this.cy.on("tap", (event) => { if (event.target === this.cy) this.#select(null) })
    this.themeObserver = new MutationObserver(() => this.cy.style(this.#style()))
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
    this.#draw()
  }

  disconnect() {
    this.themeObserver?.disconnect()
    this.cy?.destroy()
  }

  search() {
    const query = this.searchTarget.value.trim().toLowerCase()
    this.hitsTarget.replaceChildren()
    if (query.length < 2) { this.hitsTarget.hidden = true; return }

    const found = Object.values(this.byId)
      .filter((node) => node.name.toLowerCase().includes(query) || (node.files || []).some((file) => file.toLowerCase().includes(query)))
      .slice(0, MAX_ROWS)
    found.forEach((node) => {
      const hit = this.#clone(this.hitTemplateTarget)
      this.#fill(hit, "label", node.name)
      this.#fill(hit, "meta", this.#kind(node) + (node.parent ? ` · ${this.byId[node.parent].name}` : ""))
      hit.querySelector("button").addEventListener("click", () => {
        this.searchTarget.value = ""
        this.hitsTarget.hidden = true
        this.#reveal(node.id)
      })
      this.hitsTarget.append(hit)
    })
    this.hitsTarget.hidden = found.length === 0
  }

  // Drawing ---------------------------------------------------------------------------------------

  #draw() {
    this.cy.elements().remove()
    this.cy.add(this.#elements())
    if (this.selected) this.cy.getElementById(this.selected).connectedEdges().addClass("hl")
    const steps = this.#scope().some((node) => node.kind === "step" || node.kind === "data")
    const animate = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.cy.layout(steps
      ? { name: "breadthfirst", directed: true, spacingFactor: 1.15, padding: 28, animate }
      : { name: "cose", padding: 28, nodeDimensionsIncludeLabels: true, nodeRepulsion: 400000, nodeOverlap: 40, idealEdgeLength: 120, gravity: 0.2, numIter: 2000, animate, randomize: false }).run()
    this.#path()
    this.#detail()
  }

  #scope() {
    return this.focus ? (this.children[this.focus] || []) : Object.values(this.byId).filter((node) => node.level === 0)
  }

  #elements() {
    const shown = this.#scope()
    const ids = new Set(shown.map((node) => node.id))
    const elements = shown.map((node) => {
      const inner = (this.children[node.id] || []).length
      const classes = [`k-${node.kind}`, this.#inside(node) ? "" : "ext", inner ? "deep" : "", node.id === this.selected ? "sel" : ""]
      return { data: { id: node.id, label: inner ? `${node.name}  ${inner}` : node.name }, classes: classes.join(" ") }
    })

    const chain = new Set([null])
    for (let id = this.focus; id; id = this.byId[id].parent) chain.add(id)
    const lift = (id) => { for (let x = id; x; x = this.byId[x]?.parent) if (ids.has(x)) return x; return null }
    const ghostOf = (id) => { for (let x = id; x; x = this.byId[x]?.parent) if (chain.has(this.byId[x].parent)) return x; return null }

    const ghosts = new Set()
    const merged = new Map()
    this.edges.forEach((edge) => {
      const from = lift(edge.from) || ghostOf(edge.from)
      const to = lift(edge.to) || ghostOf(edge.to)
      if (!from || !to || from === to || chain.has(from) || chain.has(to)) return
      if (!ids.has(from) && !ids.has(to)) return
      ;[from, to].forEach((id) => {
        if (ids.has(id) || ghosts.has(id)) return
        ghosts.add(id)
        elements.push({ data: { id, label: this.byId[id].name }, classes: "ghost" })
      })
      const key = `${from}>${to}`
      const seen = merged.get(key)
      if (seen) { if (seen.label !== (edge.label || "")) seen.label = "" } else merged.set(key, { from, to, label: edge.label || "" })
    })
    const dense = merged.size > DENSE_EDGES
    ;[...merged.values()].forEach((edge, index) => elements.push({
      data: { id: `e${index}`, source: edge.from, target: edge.to, label: dense ? "" : edge.label },
      classes: dense ? "faint" : ""
    }))
    return elements
  }

  #style() {
    const c = PALETTE[document.documentElement.classList.contains("dark") ? "dark" : "light"]
    return [
      { selector: "node", style: { label: "data(label)", "text-valign": "center", "text-halign": "center", "font-family": "Atkinson Hyperlegible Next, ui-sans-serif, sans-serif", "font-size": 12.5, "font-weight": 500, color: c.ink, "background-color": c.surface, "border-width": 1, "border-color": c.border, shape: "round-rectangle", width: "label", height: 32, padding: "12px" } },
      { selector: "node.ext", style: { "background-color": c.subtle, color: c.muted } },
      { selector: "node.deep", style: { "border-style": "double", "border-width": 4 } },
      { selector: "node.k-page", style: { shape: "rectangle" } },
      { selector: "node.k-job", style: { shape: "cut-rectangle" } },
      { selector: "node.k-data", style: { shape: "barrel" } },
      { selector: "node.ghost", style: { "background-color": c.subtle, "border-style": "dashed", color: c.faint, "font-weight": 400 } },
      { selector: "node.sel", style: { "background-color": c.accentSoft, "border-color": c.accent, color: c.accentInk, "font-weight": 600 } },
      { selector: "edge", style: { width: 1, "line-color": c.border, "target-arrow-shape": "triangle", "target-arrow-color": c.border, "arrow-scale": 0.8, "curve-style": "bezier", label: "data(label)", "font-family": "Atkinson Hyperlegible Mono, ui-monospace, monospace", "font-size": 10, color: c.muted, "text-background-color": c.subtle, "text-background-opacity": 1, "text-background-padding": "2px", "text-rotation": "autorotate" } },
      { selector: "edge.faint", style: { opacity: 0.25 } },
      { selector: "edge.hl", style: { opacity: 1, width: 1.6, "line-color": c.accent, "target-arrow-color": c.accent, "z-index": 10 } }
    ]
  }

  // Interaction -----------------------------------------------------------------------------------

  #tap(element) {
    if (element.hasClass("ghost")) return this.#reveal(element.id())
    this.#select(element.id())
  }

  #select(id) {
    this.selected = id
    this.cy.nodes().removeClass("sel")
    this.cy.edges().removeClass("hl")
    if (id) {
      const element = this.cy.getElementById(id)
      element.addClass("sel")
      element.connectedEdges().addClass("hl")
    }
    this.#detail()
  }

  #open(id) {
    if (!(this.children[id] || []).length) return
    this.focus = id
    this.selected = null
    this.#draw()
  }

  #reveal(id) {
    const node = this.byId[id]
    this.focus = node.level === 0 ? null : node.parent
    this.selected = id
    this.#draw()
  }

  // Panels ----------------------------------------------------------------------------------------

  #path() {
    const trail = []
    for (let id = this.focus; id; id = this.byId[id].parent) trail.unshift(id)
    const crumbs = [[this.labelsValue.detail.root, null], ...trail.map((id) => [this.byId[id].name, id])]
    this.pathTarget.replaceChildren()
    crumbs.forEach(([label, id], index) => {
      if (index > 0) this.pathTarget.append(" › ")
      if (index === crumbs.length - 1) {
        const current = document.createElement("span")
        current.className = "px-1 font-semibold text-zinc-900 dark:text-zinc-100"
        current.textContent = label
        this.pathTarget.append(current)
      } else {
        const crumb = this.#clone(this.crumbTemplateTarget).firstElementChild
        crumb.textContent = label
        crumb.addEventListener("click", () => { this.focus = id; this.selected = null; this.#draw() })
        this.pathTarget.append(crumb)
      }
    })
  }

  #detail() {
    const labels = this.labelsValue.detail
    const node = this.byId[this.selected] || this.byId[this.focus]
    const view = this.#clone(this.detailTemplateTarget)
    if (!node) {
      this.#fill(view, "name", labels.root)
      this.#fill(view, "summary", labels.root_summary)
      ;["kind", "level", "files-title", "files", "no-files", "children-box", "links-box"].forEach((field) => this.#field(view, field).remove())
      this.detailTarget.replaceChildren(view)
      return
    }

    this.#fill(view, "name", node.name)
    this.#fill(view, "kind", this.#kind(node))
    this.#fill(view, "level", this.labelsValue.level.replace("%{level}", node.level))
    this.#fill(view, "summary", node.summary)
    this.#fill(view, "files-title", labels.files)
    const files = node.files || []
    files.forEach((file) => {
      const item = this.#clone(this.fileTemplateTarget).firstElementChild
      item.textContent = file
      this.#field(view, "files").append(item)
    })
    if (files.length) this.#field(view, "no-files").remove()
    else { this.#field(view, "files").remove(); this.#fill(view, "no-files", this.#inside(node) ? labels.no_files : labels.outside) }

    const inner = this.children[node.id] || []
    if (inner.length) {
      this.#fill(view, "children-title", `${labels.inside} · ${inner.length}`)
      inner.slice(0, MAX_ROWS).forEach((child) => this.#row(view, "children", child.name, this.#kind(child), () => {
        this.focus = node.id
        this.selected = child.id
        this.#draw()
      }))
      if (inner.length > MAX_ROWS) this.#fill(view, "children-more", this.labelsValue.more.replace("%{count}", inner.length - MAX_ROWS))
      else this.#field(view, "children-more").remove()
    } else this.#field(view, "children-box").remove()

    const links = this.edges.filter((edge) => edge.from === node.id || edge.to === node.id)
    if (links.length) {
      this.#fill(view, "links-title", `${labels.links} · ${links.length}`)
      links.slice(0, MAX_ROWS).forEach((edge) => {
        const outgoing = edge.from === node.id
        const other = this.byId[outgoing ? edge.to : edge.from]
        this.#row(view, "links", `${outgoing ? "→" : "←"} ${other.name}`, edge.label || "", () => this.#reveal(other.id))
      })
    } else this.#field(view, "links-box").remove()

    this.detailTarget.replaceChildren(view)
  }

  // Helpers ---------------------------------------------------------------------------------------

  #row(view, field, label, meta, onClick) {
    const row = this.#clone(this.rowTemplateTarget)
    this.#fill(row, "label", label)
    this.#fill(row, "meta", meta)
    row.querySelector("button").addEventListener("click", onClick)
    this.#field(view, field).append(row)
  }

  #inside(node) { return node.kind !== "actor" && node.kind !== "external" }
  #kind(node) { return this.labelsValue.kinds[node.kind] || node.kind }
  #clone(template) { return template.content.cloneNode(true) }
  #field(root, name) { return root.querySelector(`[data-field="${name}"]`) }
  #fill(root, name, text) { this.#field(root, name).textContent = text }
}
