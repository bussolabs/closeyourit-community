# frozen_string_literal: true

require "rails_helper"

# CYRA-632 — il flusso vero di «Scrivi il ticket per me», con un browser vero: senza JS la modale è
# solo markup, e infatti fino a ieri ask→rivedi→riempi non era mai stato eseguito da nessuna prova.
#
# Il servizio esterno non viene mai chiamato: si finge Ticketing::ComposeTicket e si esegue il job
# in linea, così la prova misura la SCHERMATA (bottone spento senza progetto, anteprima a destra,
# correzione che compare dopo la prima bozza, campi riempiti alla conferma) e non il modello.
RSpec.describe "Scrivi il ticket per me — flusso", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:other_project) { create(:project, organization: org, name: "Backoffice", key: "BCK") }

  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) }
  end

  def draft(title:, kind: "bug", knowledge: [])
    Ticketing::ComposeTicket::Draft.new(
      title:, kind:, description: "Il pagamento si pianta con la rete lenta.",
      technical_analysis: "Timeout a 30s sulla conferma.",
      scenarios: [ { title: "Rete lenta", step_given: "Sono da telefono", step_when: "Premo Paga",
                     step_then: "Torno al carrello", step_expected: "Il pagamento riesce" } ],
      conditions: [ "Con rete lenta il pagamento arriva in fondo." ], knowledge:
    )
  end

  before do
    # perform_enqueued_jobs non basta: il polling del browser deve trovare la richiesta già done.
    allow(Ai::RunJob).to receive(:perform_later) { |request| Ai::RunJob.perform_now(request) }
    sign_in_as(owner)
    visit new_member_ticket_path
    click_on_test "ticket-compose-open"
  end

  # Il difetto che gli utenti raccontavano come «non funziona»: il pulsante rispondeva solo dopo aver
  # scritto tutta la richiesta, e il menù del progetto stava dietro il backdrop della modale.
  describe "senza progetto scelto" do
    it "il pulsante è spento e dice perché, prima che si scriva qualsiasi cosa" do
      expect(page).to have_css("[data-test='ticket-compose-run'][disabled]")
      expect_test "ticket-compose-project-notice"
    end

    it "si accende scegliendo il progetto dentro la finestra" do
      select "Storefront", from: "ticket-compose-project"

      expect(page).to have_no_css("[data-test='ticket-compose-run'][disabled]")
      expect(page).to have_no_css("[data-test='ticket-compose-project-notice']", visible: true)
    end

    # Comporre per un progetto e salvare su un altro sarebbe il difetto peggiore dei due.
    it "la scelta arriva al campo del modulo che verrà salvato" do
      select "Storefront", from: "ticket-compose-project"

      expect(page).to have_field("project_id", with: project.id, type: :hidden, visible: :all)
        .or have_select("project_id", selected: "Storefront", visible: :all)
    end

    # Il menù del progetto sta dove è sempre stato, nella colonna di destra della pagina: chi lo usa
    # da lì — cioè quasi tutti — trovava il pulsante ancora spento e l'avviso «scegli prima il
    # progetto» sopra un progetto già scelto. Il controller non era agganciato al `change` del form.
    it "si accende anche scegliendo il progetto dal menù della pagina" do
      click_on_test "ticket-manual-open"
      select "Storefront", from: "project_id"
      click_on_test "ticket-compose-open"

      expect(page).to have_no_css("[data-test='ticket-compose-run'][disabled]")
      expect(page).to have_select("ticket-compose-project", selected: "Storefront")
    end
  end

  describe "prima bozza" do
    before do
      allow(Ticketing::ComposeTicket).to receive(:call)
        .and_return(Result.ok(draft(title: "Il pagamento si interrompe con la rete lenta")))
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "da telefono il pagamento si pianta"
      click_on_test "ticket-compose-run"
    end

    it "mostra la bozza nella colonna di destra, con gli scenari etichettati" do
      expect(page).to have_css("[data-test='ticket-compose-result']", text: "Il pagamento si interrompe")
      within_test("ticket-compose-result") do
        # Senza maiuscole/minuscole: le etichette dello scenario sono rese in maiuscolo dal foglio
        # di stile, quindi con gli stili compilati il browser legge «GIVEN — CONTEXT». Cercare
        # «Given» tale e quale passa solo quando gli stili NON sono stati generati.
        expect(page).to have_text(/given/i)
        expect(page).to have_text(/expected/i)
      end
    end

    # Lo spazio della correzione non esiste prima: non avrebbe niente da correggere.
    it "apre lo spazio della correzione, che prima non c'era" do
      expect_test "ticket-compose-correction"
    end

    it "non tocca il modulo finché non si conferma" do
      expect(page).to have_field("title", with: "", visible: :all)

      click_on_test "ticket-compose-fill"

      # Filling the form brings its tab back: the fields are what gets saved.
      expect(page).to have_field("title", with: "Il pagamento si interrompe con la rete lenta")
      expect(page).to have_field("description", with: /si pianta/)
    end
  end

  describe "conoscenza usata" do
    it "elenca le pagine lette" do
      allow(Ticketing::ComposeTicket).to receive(:call).and_return(
        Result.ok(draft(title: "Con conoscenza",
                        knowledge: [ { id: "a", title: "Timeout del gateway" },
                                     { id: "b", title: "Come ripetiamo le chiamate" } ]))
      )
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "il pagamento si pianta"
      click_on_test "ticket-compose-run"

      within_test("ticket-compose-knowledge") do
        expect(page).to have_text("Timeout del gateway")
        expect(page).to have_text("Come ripetiamo le chiamate")
      end
    end

    # Il caso "nessuna" si MOSTRA: una bozza che tace su cosa ha usato chiede di essere creduta sulla
    # parola, ed è il contrario di quello che questa lavorazione vuole ottenere.
    it "dice apertamente quando non ne ha trovata nessuna" do
      allow(Ticketing::ComposeTicket).to receive(:call).and_return(Result.ok(draft(title: "Senza conoscenza")))
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "il pagamento si pianta"
      click_on_test "ticket-compose-run"

      within_test("ticket-compose-knowledge") do
        expect(page).to have_text(I18n.t("member.tickets.compose.knowledge_none_hint"))
      end
    end
  end

  # Una bozza porta dentro la conoscenza del progetto per cui è stata scritta: riversarla nel modulo
  # dopo aver cambiato progetto salverebbe su un progetto un testo costruito sulle pagine di un altro.
  describe "cambio di progetto a bozza già fatta" do
    before do
      allow(Ticketing::ComposeTicket).to receive(:call).and_return(Result.ok(draft(title: "Bozza di Storefront")))
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "il pagamento si pianta"
      click_on_test "ticket-compose-run"
      expect(page).to have_css("[data-test='ticket-compose-result']", text: "Bozza di Storefront")
    end

    it "toglie la bozza e spegne «Riempi il modulo», dicendo perché" do
      select "Backoffice", from: "ticket-compose-project"

      expect(page).to have_no_css("[data-test='ticket-compose-result']", visible: true)
      expect(page).to have_css("[data-test='ticket-compose-fill'][hidden]", visible: :all)
      expect(page).to have_text(I18n.t("member.tickets.compose.project_changed"))
    end

    # La richiesta scritta è il lavoro vero: quella resta.
    it "tiene quello che l'utente aveva scritto" do
      select "Backoffice", from: "ticket-compose-project"

      expect(page).to have_field("ai-buddy-prompt", with: "il pagamento si pianta")
    end

    it "non tocca la bozza se il progetto resta lo stesso" do
      select "Storefront", from: "ticket-compose-project"

      expect(page).to have_css("[data-test='ticket-compose-result']", text: "Bozza di Storefront")
    end
  end

  describe "riscrittura con la correzione" do
    it "rimanda la correzione e sostituisce la bozza" do
      allow(Ticketing::ComposeTicket).to receive(:call)
        .and_return(Result.ok(draft(title: "Il pagamento si interrompe", kind: "bug")),
                    Result.ok(draft(title: "Far reggere il pagamento alla rete lenta", kind: "story")))
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "da telefono il pagamento si pianta"
      click_on_test "ticket-compose-run"
      expect(page).to have_css("[data-test='ticket-compose-correction']")

      fill_test "ticket-compose-correction", with: "è una story, non un bug"
      click_on_test "ticket-compose-rerun"

      expect(page).to have_css("[data-test='ticket-compose-result']", text: "Far reggere il pagamento")
      args = Ai::Request.where(kind: "ticket_compose").order(:created_at).last.args
      expect(args["correction"]).to eq("è una story, non un bug")
      expect(args["previous_draft"]).to include("title" => "Il pagamento si interrompe")
    end

    # Ricomporre lo stesso identico prompt costa un giro e non cambia niente: chi preme si aspetta
    # che qualcosa cambi.
    it "non riparte se la correzione è vuota" do
      allow(Ticketing::ComposeTicket).to receive(:call).and_return(Result.ok(draft(title: "Prima bozza")))
      select "Storefront", from: "ticket-compose-project"
      fill_test "ticket-compose-prompt", with: "il pagamento si pianta"
      click_on_test "ticket-compose-run"
      expect(page).to have_css("[data-test='ticket-compose-correction']")

      expect { click_on_test "ticket-compose-rerun" }
        .not_to change { Ai::Request.where(kind: "ticket_compose").count }
    end
  end
end
