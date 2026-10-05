# frozen_string_literal: true

require "rails_helper"

# CYRA-28 — Scorciatoie da tastiera UNIVERSALI (globali su ogni pagina member) + help modal CONDIVISO
# in sync coi binding attivi. Il layout member monta un controller `keyboard` globale che gestisce il
# set universale (? help, g+lettera navigazione, / ricerca, n nuovo, Esc chiudi) con gli stessi guard
# su typing/modifier dei controller storici. L'help è unico, centrato (m-auto, pattern CYRA-27) e
# auto-popolato: la parte universale è resa server-side dallo stesso helper della logica; le
# scorciatoie di pagina sono dichiarate dalle pagine via [data-keyboard-doc] e raccolte a runtime.
#
# Wiring (markup) verificato con rack_test (deterministico, sempre in CI). Comportamento reale
# (Scenario 1) verificato con un browser reale (`:js`, gating condiviso in spec/support/js_system.rb).
RSpec.describe "Member — scorciatoie da tastiera globali", type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # Un solo helper per rack_test e js: l'attesa del logout del form (wait) è ignorata da rack_test e
  # sincronizza il redirect Turbo sotto Chrome — evita il rimbalzo al login su `visit` successivo.
  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    expect(page).to have_no_css("[data-test='login-submit']", wait: 8)
  end

  before { Types::InstallDefaults.call(organization: org) }

  context "wiring del layout (markup, ogni pagina member)" do
    before do
      driven_by(:rack_test)
      sign_in_as(owner_account)
    end

    it "monta il controller tastiera globale una volta sul wrapper del layout" do
      visit member_tickets_path
      expect(page).to have_css("[data-controller~='keyboard']", count: 1)
    end

    it "rende l'help condiviso centrato (m-auto, w-full, max-w) come gli altri modali" do
      visit member_projects_path
      dialog = find("[data-test='keyboard-help-dialog']", visible: :all)
      # La preflight di Tailwind v4 azzera il margin:auto dello UA che centra un <dialog> modale
      # (stesso motivo di CYRA-27): serve m-auto esplicito, con larghezza responsive w-full max-w-*.
      expect(dialog[:class]).to match(/\bm-auto\b/)
      expect(dialog[:class]).to match(/\bw-full\b/)
      expect(dialog[:class]).to match(/\bmax-w-/)
    end

    it "documenta le scorciatoie universali (?, ⌘K, /, n, Esc) nell'help" do
      visit member_projects_path
      within_test("keyboard-help-universal") do
        expect(page).to have_css("kbd", text: "?")
        expect(page).to have_css("kbd", text: I18n.t("member.search.shortcut"))
        expect(page).to have_css("kbd", text: "/")
        expect(page).to have_css("kbd", text: "n")
        expect(page).to have_css("kbd", text: "Esc")
      end
    end

    it "espone le destinazioni di navigazione visibili come g+lettera, in sync col controller" do
      visit member_tickets_path
      value = find("[data-controller~='keyboard']")["data-keyboard-nav-value"]
      keys = JSON.parse(value).map { |b| b["key"] }
      expect(keys).to include("h", "t", "i", "p", "e")
      # l'help documenta le STESSE destinazioni (unica fonte helper → doc e binding in sync)
      within_test("keyboard-help-nav") do
        expect(page).to have_css("kbd", text: "g t")
        expect(page).to have_css("kbd", text: "g e")
      end
    end

    it "espone l'hook di ricerca sul toolbar delle liste (tasto /)" do
      visit member_tickets_path
      expect(page).to have_css("[data-keyboard-search]", visible: :all)
    end

    it "espone l'hook 'nuovo' sul bottone primario della lista (tasto n)" do
      visit member_tickets_path
      expect(page).to have_css("[data-keyboard-new]")
    end
  end

  context "registry di pagina — dettaglio errore (help unificato, non più locale)" do
    before do
      driven_by(:rack_test)
      sign_in_as(owner_account)
    end

    it "il bottone tastiera apre l'help globale e la pagina dichiara i suoi binding nel registry" do
      group = create(:error_group, project:, status: :unresolved)
      visit member_monitoring_error_group_path(group)

      expect(find("[data-test='shortcuts-open']")["data-action"]).to include("keyboard#openHelp")
      docs = JSON.parse(find("[data-keyboard-doc]")["data-keyboard-doc"])
      expect(docs.map { |d| d["keys"] }).to include("r", "i", "p")
      # niente più dialog help locale duplicato: l'help è quello globale del layout
      expect(page).not_to have_css("[data-test='shortcuts-dialog']", visible: :all)
    end

    it "un member in sola lettura vede solo i binding di selezione (niente triage r/i/p)" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: project)
      group = create(:error_group, project:, status: :unresolved)
      sign_in_as(member)

      visit member_monitoring_error_group_path(group)
      docs = JSON.parse(find("[data-keyboard-doc]")["data-keyboard-doc"])
      expect(docs.map { |d| d["keys"] }).not_to include("r", "i", "p")
    end
  end

  context "registry di pagina — board Kanban documentata nell'help" do
    before do
      driven_by(:rack_test)
      sign_in_as(owner_account)
    end

    it "il board dichiara i suoi binding (frecce/spazio/esc) nel registry" do
      visit member_tickets_path
      board = find("[data-test='member-board']")
      docs = JSON.parse(board["data-keyboard-doc"])
      expect(docs).to be_present
      expect(docs.first).to include("keys", "label")
    end
  end

  context "registry di pagina — dettaglio metrica" do
    before do
      driven_by(:rack_test)
      sign_in_as(owner_account)
    end

    it "il dettaglio metrica dichiara la selezione occorrenza nel registry" do
      group = create(:metric_group, project:)
      visit member_monitoring_metric_group_path(group)
      docs = JSON.parse(find("[data-keyboard-doc]")["data-keyboard-doc"])
      expect(docs.map { |d| d["keys"] }).to include("↑ ↓ · j k")
    end
  end

  # Scenario 1 del ticket: su una qualsiasi pagina member, ? apre l'help e gli universali funzionano.
  #
  # NB layout tastiera: in Chrome headless il driver NON usa il layout US, quindi Selenium send_keys("?")
  # arriva al browser come event.key "_" e send_keys("/") come "&" (i tasti shift-dipendenti sono mappati
  # sul layout di sistema). Per questi si dispatcha un KeyboardEvent con la key LOGICA — esattamente ciò
  # che il browser genera quando l'utente preme quel tasto sul proprio layout. Le lettere (g/t/n) arrivano
  # invece corrette e usano l'input reale send_keys.
  context "comportamento reale (browser)", :js do
    before { sign_in_as(owner_account) }

    def press_key(key)
      page.execute_script(
        "window.dispatchEvent(new KeyboardEvent('keydown', { key: arguments[0], bubbles: true, cancelable: true }))", key
      )
    end

    # Spia delle navigazioni, per poter asserire che una navigazione NON è avvenuta senza concedere
    # un tempo a quella che non deve partire (CYRA-732). Turbo annuncia ogni visita con
    # `turbo:before-visit` nello stesso giro dell'evento che l'ha chiesta — anche quando la chiede
    # `Turbo.visit` da codice, com'è per le scorciatoie `g <lettera>`. Contare l'INIZIO invece della
    # fine è anche più severo del guardare dove si è finiti: prende pure la visita che parte e viene
    # poi annullata, che a schermo non lascerebbe traccia.
    def spia_visite_turbo
      page.execute_script(<<~JS)
        window.__cyiVisiteTurbo = []
        document.addEventListener(
          "turbo:before-visit",
          (event) => window.__cyiVisiteTurbo.push((event.detail && event.detail.url) || "?")
        )
      JS
    end

    def visite_turbo = page.evaluate_script("window.__cyiVisiteTurbo")

    it "? apre l'help condiviso su una pagina member qualsiasi" do
      visit member_tickets_path
      expect(page).to have_no_css("[data-test='keyboard-help-dialog'][open]")
      press_key("?")
      expect(page).to have_css("[data-test='keyboard-help-dialog'][open]")
    end

    it "g poi t naviga ai ticket da un'altra pagina" do
      visit member_projects_path
      spia_visite_turbo
      find("body").send_keys("g")
      find("body").send_keys("t")
      expect(page).to have_current_path(member_tickets_path, ignore_query: true)
      # La stessa spia con cui più sotto si prova che una navigazione NON parte: qui, dove la
      # navigazione ci deve essere, si prova che la spia la vede. Senza questa metà, il giorno in cui
      # Turbo smettesse di annunciare le visite l'asserzione negativa resterebbe verde per sempre.
      expect(visite_turbo).to include(a_string_including(member_tickets_path))
    end

    # Il fuoco lo sposta il browser dopo il tasto, non Capybara: `evaluate_script` legge una volta
    # sola e su una macchina carica legge troppo presto — due rilasci fermati da qui, sempre verde
    # riprovandolo. `wait_until` rilegge finché la condizione è vera e non allenta la verifica: il
    # fuoco deve comunque finire sul campo di ricerca, solo entro il tempo che Capybara concede a
    # tutto il resto.
    it "/ mette a fuoco il campo ricerca della lista" do
      visit member_tickets_path
      press_key("/")

      wait_until("il fuoco è finito sul campo di ricerca") do
        page.evaluate_script("document.activeElement.matches('[data-keyboard-search]')")
      end
    end

    # CYRA-933: New opens in the modal over the list, so the address stays on the list.
    it "n attiva il nuovo dalla lista" do
      visit member_tickets_path
      find("body").send_keys("n")
      within("dialog[data-test='member-modal'][open]") { expect(page).to have_css("[data-test='ticket-form']") }
      expect(page).to have_current_path(member_tickets_path, ignore_query: true)
    end

    it "ignora le scorciatoie mentre si digita in un campo (guard typing)" do
      visit member_tickets_path
      # dispatch SULL'input (event.target = campo editabile) → il guard deve sopprimere lo shortcut
      page.execute_script(
        "var el = document.querySelector('[data-keyboard-search]'); el.focus(); " \
        "el.dispatchEvent(new KeyboardEvent('keydown', { key: '?', bubbles: true, cancelable: true }))"
      )
      expect(page).to have_no_css("[data-test='keyboard-help-dialog'][open]")
    end

    it "l'help mostra la sezione 'questa pagina' popolata dai binding dichiarati" do
      group = create(:error_group, project:, status: :unresolved)
      visit member_monitoring_error_group_path(group)
      press_key("?")
      within_test("keyboard-help-page") do
        expect(page).to have_css("kbd", text: "r")
      end
    end

    it "con l'help aperto sopprime gli universali (nessuna azione su elementi dietro il modale)" do
      visit member_projects_path
      press_key("?")
      expect(page).to have_css("[data-test='keyboard-help-dialog'][open]")
      spia_visite_turbo
      # Col modale aperto il focus è nel dialog: un keydown g/t bubbla comunque a window e va soppresso.
      press_key("g")
      press_key("t")
      # La NON-navigazione si asserisce sulla spia, non sul tempo: `press_key` esegue uno script nel
      # browser e torna solo a gestore del keydown finito, quindi una visita, se ci fosse stata,
      # sarebbe GIÀ stata annunciata quando si legge. `have_current_path`/`have_no_css` da soli non
      # basterebbero — si soddisferebbero sullo stato di prima mentre la visita è ancora in volo —
      # ma restano sotto come seconda rete: la pagina è ancora quella, il modale ancora aperto.
      expect(visite_turbo).to be_empty
      expect(page).to have_current_path(member_projects_path, ignore_query: true)
      expect(page).to have_no_css("[data-test='member-board']")
      expect(page).to have_css("[data-test='keyboard-help-dialog'][open]")
    end
  end
end
