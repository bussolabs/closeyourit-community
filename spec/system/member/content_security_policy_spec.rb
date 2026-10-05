# frozen_string_literal: true

require "rails_helper"

# CYRA-715 — la protezione contro gli script iniettati era accesa a metà: il browser segnalava le
# violazioni e non bloccava niente. Ora blocca. Questa prova serve al secondo mezzo della richiesta,
# quello che nessun test server-side può vedere: che nulla di NOSTRO finisca fra le cose bloccate.
#
# Un blocco della policy non è un errore del server e non lascia una pagina rotta: la pagina si
# disegna intera e semplicemente un pezzo non parte. L'unico posto dove appare è la console del
# browser — quindi la si legge, invece di supporre.
RSpec.describe "Member — la protezione contro gli script iniettati", type: :system, js: true do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  # Il buffer della console è DEL BROWSER, che resta acceso per tutto il processo: senza svuotarlo
  # prima di misurare, un esempio si prende le righe di quello prima — compresa la violazione che un
  # altro esempio provoca apposta, e la prova diventa rossa per il motivo sbagliato.
  def svuota_console
    page.driver.browser.logs.get(:browser)
  end

  # Le violazioni registrate DA QUANDO si è svuotato. `logs.get` svuota a ogni lettura: una volta
  # sola per pagina, dopo che la pagina è viva.
  def violazioni_csp
    page.driver.browser.logs.get(:browser).map(&:message).select do |riga|
      riga.include?("Content Security Policy") || riga.include?("Refused to")
    end
  end

  it "l'area utenti blocca davvero: uno script iniettato nella pagina non parte" do
    sign_in_as(owner)
    visit member_tickets_path

    # Lo stesso che farebbe un contenuto malevolo: markup con dentro uno script senza autorizzazione.
    # L'iniezione passa dal driver (che non è soggetto alla policy) proprio perché è la PAGINA a
    # doverla rifiutare, non il modo in cui ci arriva.
    page.execute_script(<<~JS)
      window.__iniettato = false
      const script = document.createElement("script")
      script.textContent = "window.__iniettato = true"
      document.body.appendChild(script)
    JS

    expect(page.evaluate_script("window.__iniettato")).to be(false)
  end

  it "le pagine dell'area utenti non bloccano niente di nostro" do
    create(:log_entry, project:, message: "disk almost full")
    sign_in_as(owner)

    [ member_tickets_path, member_monitoring_log_entries_path, member_monitoring_vulnerabilities_path ]
      .each do |percorso|
        svuota_console
        visit percorso
        expect(page).to have_css("h1", wait: 8)
        expect(violazioni_csp).to be_empty, "#{percorso} ha una risorsa bloccata dalla policy"
      end
  end

  # La segnalazione a cui questa prova risponde: con Turbo Drive la pagina nuova arriva via fetch e
  # NON sostituisce la policy attiva, che resta quella della prima risposta. Un nonce diverso a ogni
  # richiesta potrebbe quindi consegnare agli script della pagina nuova una firma che la policy in
  # vigore non riconosce. Qui si naviga davvero con Turbo — il marcatore su `window` lo dimostra: un
  # ricaricamento completo lo cancellerebbe, e la prova non proverebbe niente.
  it "navigando fra le pagine senza ricaricare non si blocca niente" do
    sign_in_as(owner)
    visit member_monitoring_log_entries_path
    expect(page).to have_css("h1", wait: 8)
    page.execute_script("window.__stessoDocumento = true")
    svuota_console

    click_on_test "member-nav-todos"
    expect(page).to have_current_path(member_todo_lists_path, wait: 8)
    click_on_test "member-nav-chat"
    expect(page).to have_current_path(member_chat_conversations_path, wait: 8)

    expect(page.evaluate_script("window.__stessoDocumento")).to be(true),
      "la pagina si è ricaricata da capo: la prova non dice niente su Turbo Drive"
    expect(violazioni_csp).to be_empty
  end

  # Il caso che vanificherebbe tutto il resto: la protezione attiva è quella del PRIMO documento
  # caricato, e Turbo non la sostituisce navigando. Chi entra dalla porta normale — sito pubblico,
  # «Accedi», area riservata — si porterebbe dietro per tutta la visita la protezione del sito
  # pubblico, che segnala e basta. L'enforce ci sarebbe negli header e non nel browser.
  it "entrando dal sito pubblico l'area riservata blocca lo stesso" do
    visit "/"
    expect(page).to have_css("[data-test='website-nav-signin']", wait: 8)
    # Il marcatore muore col documento: se sopravvive fino all'area riservata, vuol dire che si è
    # arrivati fin lì SENZA mai ricaricare — e allora la protezione attiva è ancora quella del sito
    # pubblico, che segnala e basta. È esattamente il caso che questa prova deve escludere.
    page.execute_script("window.__documentoPubblico = true")

    click_on_test "website-nav-signin"
    expect(page).to have_css("[data-test='login-submit']", wait: 8)
    fill_test "login-email", with: owner.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    expect(page).to have_no_css("[data-test='login-submit']", wait: 8)

    expect(page.evaluate_script("window.__documentoPubblico")).to be_nil,
      "si è entrati nell'area riservata senza ricaricare: vale ancora la protezione del sito pubblico"

    page.execute_script(<<~JS)
      window.__iniettato = false
      const script = document.createElement("script")
      script.textContent = "window.__iniettato = true"
      document.body.appendChild(script)
    JS

    expect(page.evaluate_script("window.__iniettato")).to be(false)
  end

  it "l'elenco dei log si apre ancora premendo la riga" do
    entry = create(:log_entry, project:, message: "disk almost full")
    sign_in_as(owner)

    visit member_monitoring_log_entries_path
    find("[data-test='log-entry-row']").click

    expect(page).to have_current_path(member_monitoring_log_entry_path(entry), wait: 8)
  end
end
