import { Controller } from "@hotwired/stimulus"

// Composizione assistita del ticket (in interfaccia: «Scrivi per me» — CYRA-398, il nome
// «AI Buddy» non diceva a nessuno cosa facesse): l'utente descrive cosa gli serve, preme il pulsante
// e l'assistente compone l'INTERO ticket (POST /member/tickets/compose → 202 → poll dell'esito). La
// bozza NON riempie subito il form: viene mostrata read-only nella colonna di destra (renderDraft)
// perché l'utente la controlli; solo con "Riempi il modulo" (applyFill) i valori vengono scritti in
// titolo, tipo (radio, notificando ticket-kind così toggla il blocco bug + i marker), descrizione e
// le clausole Given/When/Then/Expected. I campi restano la verità del form (validati lato server):
// questo è solo input-assist. Progressive enhancement: senza JS il form resta compilabile a mano.
//
// CYRA-632 — tre cose nuove:
// · il PROGETTO si sceglie nella modale, con un select specchio di quello del form. La sincronia va
//   in entrambi i versi, o si finisce col comporre per un progetto e salvare su un altro.
// · il pulsante nasce SPENTO senza progetto e dice perché. Prima l'errore arrivava dopo aver scritto
//   tutta la richiesta e premuto — quando il lavoro era già fatto e il rimedio stava dietro il
//   backdrop di una modale in top-layer.
// · la CORREZIONE: rerun() rimanda testo + correzione + l'id della richiesta precedente, e il server
//   rilegge da lì la bozza da correggere. Il secondo giro RISCRIVE, non ricompone.
export default class extends Controller {
  static targets = [
    "prompt", "status", "button", "result", "fillButton", "empty",
    "projectSelect", "projectNotice", "correctionPanel", "correction", "rerunButton",
    "knowledge", "rewritten", "keepEditing",
  ]
  static values = {
    composeUrl: String,
    pollUrl: String,
    generatingMessage: String,
    failedMessage: String,
    reviewMessage: String,
    projectChangedMessage: String,
    labels: Object,
  }

  connect() {
    // Il progetto può arrivare già scelto (creazione da un progetto, o form ripresentato dopo un
    // errore di validazione): lo stato del pulsante si allinea al connect, non al primo click.
    this.syncProjectAvailability()
  }

  // ─── Progetto ──────────────────────────────────────────────────────────────

  // Scelta dal select della modale → la si riporta sul campo del form, che è quello che verrà
  // salvato, e si notifica `change` così ticket-milestone/parent/platforms ricaricano le loro liste
  // come se l'utente avesse usato il menù della pagina. Senza la notifica il ticket si salverebbe
  // sul progetto giusto ma con milestone ed epic dell'altro.
  projectChanged() {
    const field = this.projectField
    if (field && this.hasProjectSelectTarget && field.value !== this.projectSelectTarget.value) {
      field.value = this.projectSelectTarget.value
      // Il `change` sul campo del form risale fino al form, dove ticket-compose#projectSynced
      // rimette in fila tutto: un percorso solo, qualunque sia il menù da cui si è scelto.
      field.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }
    this.projectSynced()
  }

  // Agganciato al `change` del FORM, non del solo menù della modale: il progetto si sceglie anche
  // dalla colonna di destra della pagina, e quella scelta deve arrivare qui. Senza, chi sceglieva il
  // progetto dove è sempre stato — cioè quasi tutti — trovava il pulsante ancora spento e l'avviso
  // «scegli prima il progetto» sopra un progetto già scelto: esattamente il difetto da correggere.
  //
  // Scatta a ogni change del form (anche titolo o priorità): entrambe le cose che fa sono a vuoto
  // quando il progetto non è cambiato, come già fanno ticket-milestone e i suoi vicini.
  projectSynced() {
    this.syncProjectAvailability()
    this.discardDraftOfAnotherProject()
  }

  // Una bozza porta dentro la conoscenza del progetto per cui è stata scritta. Riversarla nel modulo
  // dopo aver cambiato progetto significherebbe salvare su un progetto un testo costruito sulle
  // pagine di un altro — in silenzio, che è il modo peggiore. Cambiato il progetto, l'assistente
  // riparte: la richiesta scritta resta (è il lavoro vero), la bozza no.
  discardDraftOfAnotherProject() {
    if (!this.draft || this.composedProjectId === this.projectId) return

    this.draft = null
    this.lastRequestId = null
    this.composedProjectId = null
    if (this.hasResultTarget) {
      this.resultTarget.replaceChildren()
      this.resultTarget.hidden = true
    }
    if (this.hasKnowledgeTarget) {
      this.knowledgeTarget.replaceChildren()
      this.knowledgeTarget.hidden = true
    }
    if (this.hasCorrectionTarget) this.correctionTarget.value = ""
    if (this.hasEmptyTarget) this.emptyTarget.hidden = false
    if (this.hasFillButtonTarget) this.fillButtonTarget.hidden = true
    if (this.hasKeepEditingTarget) this.keepEditingTarget.hidden = true
    if (this.hasRewrittenTarget) this.rewrittenTarget.hidden = true
    if (this.hasCorrectionPanelTarget) this.correctionPanelTarget.hidden = true
    this.showStatus(this.projectChangedMessageValue, "info")
  }

  syncProjectAvailability() {
    // Dal CYRA-765 l'unica porta è il progetto: l'AI la offre il sistema, non c'è più un servizio
    // da collegare per organizzazione.
    const usable = Boolean(this.projectId)
    // Lo specchio si allinea anche nel verso opposto: il menù della pagina resta usabile, e chi lo
    // usa a modale chiusa deve ritrovarsi la scelta qui dentro.
    if (this.hasProjectSelectTarget && this.projectSelectTarget.value !== this.projectId) {
      this.projectSelectTarget.value = this.projectId
    }
    if (this.hasProjectNoticeTarget) this.projectNoticeTarget.hidden = usable
    if (this.hasButtonTarget) this.buttonTarget.disabled = !usable
    if (this.hasRerunButtonTarget) this.rerunButtonTarget.disabled = !usable
  }

  // ─── Comporre e riscrivere ─────────────────────────────────────────────────

  run(event) {
    return this.compose(event, {})
  }

  // Il secondo giro. Senza correzione scritta non parte: sarebbe una ricomposizione identica pagata
  // due volte, e chi ha premuto si aspetta che qualcosa cambi.
  rerun(event) {
    const correction = this.hasCorrectionTarget ? this.correctionTarget.value.trim() : ""
    if (!correction) {
      if (this.hasCorrectionTarget) this.correctionTarget.focus()
      return Promise.resolve()
    }
    return this.compose(event, { correction, previous_request_id: this.lastRequestId })
  }

  async compose(event, extra) {
    event.preventDefault()
    const text = this.hasPromptTarget ? this.promptTarget.value.trim() : ""
    if (!text) {
      if (this.hasPromptTarget) this.promptTarget.focus()
      return
    }
    // Rete di sicurezza: il pulsante è già spento senza progetto, ma la sincronia potrebbe non
    // essere passata di qui (form ricostruito, target mancante).
    if (!this.projectId) {
      this.syncProjectAvailability()
      return
    }

    this.setBusy(true)
    this.showStatus(this.generatingMessageValue, "info")
    try {
      const response = await fetch(this.composeUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({ project_id: this.projectId, text, ...extra }),
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        this.showStatus(payload?.error?.message || this.failedMessageValue, "error")
        return
      }
      // 202 + request_id: la composizione gira in background, l'esito si polla. L'id si tiene: è
      // quello che il giro dopo manderà come `previous_request_id` per farsi correggere la bozza.
      const requestId = payload?.data?.request_id
      const result = requestId ? await this.poll(requestId) : payload.data || {}
      // NON riempie subito: mostra la bozza per la review, poi "Riempi il modulo" scrive nel form.
      if (!result || !result.title) {
        this.showStatus(this.failedMessageValue, "error")
        return
      }
      this.draft = result
      this.lastRequestId = requestId
      // Il progetto per cui questa bozza è stata scritta: serve a riconoscerla come non più valida
      // se il progetto cambia (vedi discardDraftOfAnotherProject).
      this.composedProjectId = this.projectId
      this.renderDraft(result)
      this.renderKnowledge(result.knowledge)
      this.revealAfterDraft(Boolean(extra.correction))
      this.showStatus(this.reviewMessageValue, "ok")
    } catch (error) {
      this.showStatus(error.userMessage || this.failedMessageValue, "error")
    } finally {
      this.setBusy(false)
    }
  }

  async poll(requestId) {
    const url = this.pollUrlValue.replace(":id", requestId)
    const deadline = Date.now() + 90000
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 1500))
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) break
      const data = (await response.json().catch(() => ({})))?.data || {}
      if (data.status === "done") return data.result || {}
      if (data.status === "failed") {
        const error = new Error(data.error?.message || "failed")
        error.userMessage = data.error?.message
        throw error
      }
    }
    throw new Error("timeout")
  }

  // Quello che compare solo a bozza pronta. Lo spazio della correzione non c'è prima: non avrebbe
  // niente da correggere, e mostrarlo vuoto insegnerebbe che va compilato per partire.
  revealAfterDraft(rewritten) {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = true
    if (this.hasFillButtonTarget) this.fillButtonTarget.hidden = false
    if (this.hasKeepEditingTarget) this.keepEditingTarget.hidden = false
    if (this.hasCorrectionPanelTarget) this.correctionPanelTarget.hidden = false
    if (this.hasRewrittenTarget) this.rewrittenTarget.hidden = !rewritten
  }

  // ─── Anteprima ─────────────────────────────────────────────────────────────

  // "Riempi il modulo": scrive la bozza approvata nei campi del form. A tornare sulla scheda del
  // modulo pensa la seconda azione (ticket-entry#showFirst) sullo stesso bottone.
  applyFill() {
    if (this.draft) this.fill(this.draft)
  }

  // Preview read-only della bozza (label localizzate da labelsValue; textContent, mai innerHTML, sui
  // dati AI). Un nuovo giro sovrascrive la preview.
  renderDraft(data) {
    if (!this.hasResultTarget) return
    const labels = this.labelsValue || {}
    const kindLabels = labels.kinds || {}
    this.resultTarget.replaceChildren()
    this.appendField(labels.title, data.title)
    this.appendField(labels.kind, kindLabels[data.kind] || data.kind)
    this.appendField(labels.description, data.description)
    ;(data.scenarios || []).forEach((scenario, index) => {
      this.appendScenario(labels, scenario, index)
    })
    if ((data.conditions || []).length) this.appendField(labels.conditions, data.conditions.join("\n"))
    this.appendField(labels.technical_analysis, data.technical_analysis)
    this.resultTarget.hidden = false
  }

  // Le quattro clausole con la loro etichetta. Prima erano un join("\n") in un blocco unico: le
  // label Given/When/Then/Expected arrivavano già serializzate in labelsValue e non le leggeva
  // nessuno, così l'anteprima di uno scenario BDD si leggeva come quattro righe di prosa slegate.
  appendScenario(labels, scenario, index) {
    const box = document.createElement("div")
    box.className = "rounded-md border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-2.5 flex flex-col gap-1.5"

    const heading = document.createElement("p")
    heading.className = "text-[12px] font-semibold text-zinc-900 dark:text-zinc-100"
    heading.textContent = scenario.title || `${labels.scenarios} ${index + 1}`
    box.appendChild(heading)

    const steps = [
      [labels.given, scenario.step_given],
      [labels.when, scenario.step_when],
      [labels.then, scenario.step_then],
      [labels.expected, scenario.step_expected],
    ]
    steps.forEach(([label, value]) => {
      if (!value) return
      const row = document.createElement("div")
      row.className = "grid grid-cols-[62px_minmax(0,1fr)] gap-2"
      const key = document.createElement("span")
      key.className = "font-mono uppercase text-[9px] tracking-[0.8px] text-indigo-600 dark:text-indigo-400 pt-0.5"
      key.textContent = label || ""
      const val = document.createElement("span")
      val.className = "text-[12px] text-zinc-900 dark:text-zinc-100 leading-snug"
      val.textContent = value
      row.appendChild(key)
      row.appendChild(val)
      box.appendChild(row)
    })

    this.resultTarget.appendChild(box)
  }

  appendField(label, value) {
    if (value == null || value === "") return
    const row = document.createElement("div")
    const key = document.createElement("p")
    key.className = "font-mono uppercase text-[9px] tracking-[1px] text-gray-400 dark:text-zinc-500"
    key.textContent = label || ""
    const val = document.createElement("p")
    val.className = "text-[12.5px] text-zinc-900 dark:text-zinc-100 whitespace-pre-line"
    val.textContent = value
    row.appendChild(key)
    row.appendChild(val)
    this.resultTarget.appendChild(row)
  }

  // Le pagine che l'assistente ha letto, o il fatto che non ne abbia letta nessuna. Il caso "nessuna"
  // si mostra e non si nasconde: una bozza che tace su cosa ha usato chiede di essere creduta sulla
  // parola, ed è esattamente ciò che qui non vogliamo.
  renderKnowledge(pages) {
    if (!this.hasKnowledgeTarget) return
    const labels = this.labelsValue || {}
    const used = pages || []
    this.knowledgeTarget.replaceChildren()

    const heading = document.createElement("p")
    heading.className = "font-mono uppercase text-[9px] tracking-[1px] text-gray-400 dark:text-zinc-500"
    heading.textContent = used.length
      ? (used.length === 1 ? labels.knowledge_used_one : (labels.knowledge_used_other || "").replace("%{count}", used.length))
      : labels.knowledge_none
    this.knowledgeTarget.appendChild(heading)

    if (!used.length) {
      const hint = document.createElement("p")
      hint.className = "text-[12px] text-gray-500 dark:text-zinc-400 leading-relaxed"
      hint.textContent = labels.knowledge_none_hint || ""
      this.knowledgeTarget.appendChild(hint)
    } else {
      used.forEach((page) => {
        const row = document.createElement("p")
        row.className = "text-[12px] text-zinc-900 dark:text-zinc-100 font-medium"
        row.textContent = `· ${page.title}`
        this.knowledgeTarget.appendChild(row)
      })
    }
    this.knowledgeTarget.hidden = false
  }

  // ─── Scrittura nel form ────────────────────────────────────────────────────

  fill(data) {
    this.setValue('[name="title"]', data.title)
    this.setKind(data.kind)
    this.setValue('[name="description"]', data.description)
    this.setValue('[name="technical_analysis"]', data.technical_analysis)
    const scenarios = this.nestedController("scenarios")
    if (scenarios && (data.scenarios || []).length) scenarios.replaceRows(data.scenarios)
    const conditions = this.nestedController("conditions")
    if (conditions && (data.conditions || []).length) conditions.replaceRows(data.conditions.map((text) => ({ text })))
  }

  setValue(selector, value) {
    if (value == null) return
    const field = this.element.querySelector(selector)
    if (!field) return

    field.value = value
    // Riempire .value non emette `input`: senza questo, il contatore caratteri (char-counter)
    // resterebbe fermo sul valore precedente dopo un fill AI.
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  // Il controller nested-fields del repeater scenari/DoD (per pre-compilarlo dalla bozza AI).
  nestedController(kind) {
    const element = document.querySelector(`[data-nested-kind='${kind}']`)
    return element ? this.application.getControllerForElementAndIdentifier(element, "nested-fields") : null
  }

  // Seleziona il radio del tipo e notifica ticket-kind (change) così toggla il blocco bug + i marker.
  setKind(kind) {
    if (!kind) return
    const radio = this.element.querySelector(`input[name="kind"][value="${kind}"]`)
    if (!radio) return
    radio.checked = true
    radio.dispatchEvent(new Event("change", { bubbles: true }))
  }

  // ─── Utilità ───────────────────────────────────────────────────────────────

  // Il campo del form: hidden input (progetto bloccato) o select della sidebar. È lui la verità —
  // il select della modale ne è lo specchio, e quello che si salva è questo.
  get projectField() {
    return this.element.querySelector('[name="project_id"]')
  }

  get projectId() {
    const field = this.projectField
    return field ? field.value : ""
  }

  setBusy(busy) {
    // A lavorazione finita i pulsanti tornano attivi solo se un progetto c'è ancora: rimetterli
    // accesi a scatola chiusa riaprirebbe la strada alla richiesta che il server rifiuta con un 404.
    if (busy) {
      if (this.hasButtonTarget) this.buttonTarget.disabled = true
      if (this.hasRerunButtonTarget) this.rerunButtonTarget.disabled = true
    } else {
      this.syncProjectAvailability()
    }
  }

  showStatus(message, kind) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden", "text-emerald-700", "dark:text-emerald-300", "text-red-600", "dark:text-red-400", "text-gray-500", "dark:text-zinc-400")
    const tone = kind === "ok" ? [ "text-emerald-700", "dark:text-emerald-300" ] : kind === "error" ? [ "text-red-600", "dark:text-red-400" ] : [ "text-gray-500", "dark:text-zinc-400" ]
    this.statusTarget.classList.add(...tone)
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
