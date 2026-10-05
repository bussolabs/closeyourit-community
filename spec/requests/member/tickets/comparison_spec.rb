# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets — gate duplicati con pagina di confronto", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:done_status) { create(:ticket_status, :done, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  around do |example|
    old_url = ENV["EMBED_BASE_URL"]
    old_key = ENV["AI_API_KEY"]
    ENV["EMBED_BASE_URL"] = "http://embed.test:7997"
    ENV["AI_API_KEY"] = "test-key"
    example.run
  ensure
    old_url ? ENV["EMBED_BASE_URL"] = old_url : ENV.delete("EMBED_BASE_URL")
    old_key ? ENV["AI_API_KEY"] = old_key : ENV.delete("AI_API_KEY")
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def seeded_ticket(index, title:, project: self.project, status: self.status)
    create(:ticket, organization: org, project: project, title: title, status: status).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def stub_embed(vector)
    stub_request(:post, "http://embed.test:7997/embeddings")
      .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
  end

  def create_params(overrides = {})
    { project_id: project.id, title: "Crash al login su submit form", kind: "bug",
      description: "Il login esplode inviando il form",
      status_id: status.id, priority_id: priority.id }.merge(overrides)
  end

  describe "POST /member/tickets (gate)" do
    it "con un simile quasi identico nello stesso progetto mostra il confronto senza creare" do
      twin = seeded_ticket(0, title: "Crash al login")
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"ticket-comparison\"")
      expect(response.body).to include(twin.code)
    end

    it "un ticket solo somigliante non ferma più la creazione: sotto la soglia si crea e basta" do
      seeded_ticket(0, title: "Crash al login")
      # 85%: abbastanza per comparire nel pannello, non abbastanza per fermare chi sta creando.
      stub_embed(blend_vector(0, 1, weight: 0.85))
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .to change(Ticketing::Ticket, :count).by(1)
    end

    it "chi ha già spuntato un simile non rivede il confronto, e il ticket nasce collegato" do
      twin = seeded_ticket(0, title: "Crash al login")
      stub_embed(basis_vector(0)) # 100%: senza spunta il confronto scatterebbe di sicuro
      sign_in(member)

      expect { post member_tickets_path, params: create_params(link_ticket_ids: [ twin.id ]) }
        .to change(Ticketing::Ticket, :count).by(1)
        .and change(Connections::TicketLink, :count).by(1)

      created = Ticketing::Ticket.order(:created_at).last
      expect(response).to redirect_to(member_ticket_path(created))
      link = Connections::TicketLink.last
      expect(link.related).to eq(twin)
      expect(link.kind).to eq("related")
      expect(twin.events.pluck(:action)).to include("linked")
    end

    it "collega tutti i simili spuntati in un colpo solo" do
      first = seeded_ticket(0, title: "Crash al login")
      second = seeded_ticket(1, title: "Crash al login da mobile")
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params(link_ticket_ids: [ first.id, second.id ]) }
        .to change(Connections::TicketLink, :count).by(2)

      # includes: leggere i collegati uno per uno sarebbe una query per link, e la scansione N+1 è
      # attiva anche sulle asserzioni.
      created_links = Ticketing::Ticket.order(:created_at).last.links.includes(:related)
      expect(created_links.map(&:related)).to match_array([ first, second ])
    end

    it "se nessun collegamento riesce lo dice, invece di annunciare solo il ticket creato" do
      # Tutti i bersagli scelti spariti fra la spunta e il salvataggio: il ticket nasce comunque, ma
      # chi aveva chiesto i collegamenti deve sapere che non ci sono — altrimenti li dà per scritti.
      ghost = create(:ticket, organization: org, project: create(:project, organization: org))
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params(link_ticket_ids: [ ghost.id ]) }
        .to change(Ticketing::Ticket, :count).by(1)
        .and not_change(Connections::TicketLink, :count)

      expect(flash[:notice]).to eq(I18n.t("member.tickets.duplicates.created_not_linked"))
    end

    it "non collega più ticket di quanti il pannello ne possa proporre" do
      # Sette fixture uguali nel setup: la scansione N+1 copre l'intero example, non solo la
      # richiesta (spec/support/prosopite.rb).
      extra = allow_n_plus_one do
        Array.new(Ticketing::FindSimilarTickets::TOP_K + 2) { |i| seeded_ticket(i, title: "Crash al login #{i}") }
      end
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params(link_ticket_ids: extra.map(&:id)) }
        .to change(Connections::TicketLink, :count).by(Ticketing::FindSimilarTickets::TOP_K)
    end

    it "un id spuntato che nel frattempo non è più valido non fa perdere il ticket appena scritto" do
      twin = seeded_ticket(0, title: "Crash al login")
      hidden = create(:ticket, organization: org, project: create(:project, organization: org))
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params(link_ticket_ids: [ twin.id, hidden.id ]) }
        .to change(Ticketing::Ticket, :count).by(1)
        .and change(Connections::TicketLink, :count).by(1)

      expect(Connections::TicketLink.last.related).to eq(twin)
    end

    it "senza simili crea il ticket come sempre" do
      seeded_ticket(0, title: "Tutt'altro argomento")
      stub_embed(basis_vector(5))
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .to change(Ticketing::Ticket, :count).by(1)
      expect(response).to redirect_to(member_ticket_path(Ticketing::Ticket.order(:created_at).last))
    end

    it "un simile in un ALTRO progetto non fa scattare il gate (scope stesso progetto)" do
      other_project = create(:project, organization: org)
      create(:project_membership, account: member, project: other_project)
      seeded_ticket(0, title: "Crash al login", project: other_project)
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .to change(Ticketing::Ticket, :count).by(1)
    end

    it "un simile CHIUSO oltre la finestra non fa scattare il gate; dentro la finestra sì" do
      outside = seeded_ticket(0, title: "Crash al login vecchio", status: done_status)
      outside.update_columns(closed_at: (Ticketing::Constants::DUPLICATE_CLOSED_WINDOW + 1.day).ago)
      stub_embed(basis_vector(0))
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .to change(Ticketing::Ticket, :count).by(1)

      inside = seeded_ticket(0, title: "Crash al login recente", status: done_status)
      inside.update_columns(closed_at: 2.days.ago)

      expect { post member_tickets_path, params: create_params }
        .not_to change(Ticketing::Ticket, :count)
      expect(response.body).to include("data-test=\"ticket-comparison\"")
    end

    it "servizio embedding giù → crea normalmente (degrado silenzioso)" do
      seeded_ticket(0, title: "Crash al login")
      stub_request(:post, "http://embed.test:7997/embeddings").to_timeout
      sign_in(member)

      expect { post member_tickets_path, params: create_params }
        .to change(Ticketing::Ticket, :count).by(1)
    end
  end

  describe "POST /member/tickets (esiti del confronto)" do
    let!(:twin) { seeded_ticket(0, title: "Crash al login") }

    before do
      stub_embed(basis_vector(0))
      sign_in(member)
    end

    it "dedup_ack=back ripresenta il form col draft, senza creare" do
      expect { post member_tickets_path, params: create_params(dedup_ack: "back") }
        .not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Crash al login su submit form")
    end

    it "«Torna al form» non riporta indietro il bersaglio preselezionato del confronto" do
      # Sulla pagina di confronto il primo candidato è già spuntato, e «Torna al form» invia tutto
      # il form: senza questo, si tornerebbe al form con un collegamento che nessuno ha scelto — e
      # al salvataggio dopo salterebbe pure il confronto, scrivendolo di nascosto.
      post member_tickets_path, params: create_params(dedup_ack: "back", link_ticket_ids: [ twin.id ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("name=\"link_ticket_ids[]\"")
    end

    it "senza nessun ticket spuntato «Crea e collega» lo dice, invece di rispondere «non trovato»" do
      expect {
        post member_tickets_path, params: create_params(dedup_ack: "link", link_ticket_ids: [],
                                                        link_kind: "duplicate")
      }.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("member.tickets.comparison.errors.no_target_selected"))
    end

    it "dedup_ack=create con motivazione crea il ticket con la motivazione in descrizione" do
      expect {
        post member_tickets_path, params: create_params(dedup_ack: "create", dedup_reason: "Endpoint diverso")
      }.to change(Ticketing::Ticket, :count).by(1)

      ticket = Ticketing::Ticket.order(:created_at).last
      expect(ticket.description).to include("Endpoint diverso")
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "«Crea comunque» non annuncia collegamenti mancati: quelle caselle non le ha chieste nessuno" do
      # Il form del confronto è uno solo, quindi le caselle preselezionate viaggiano anche con
      # questo pulsante. Contarle vorrebbe dire dire a chi ha scelto «crea comunque» che un
      # collegamento non è stato scritto — un collegamento che non aveva chiesto.
      post member_tickets_path, params: create_params(dedup_ack: "create", dedup_reason: "Altro endpoint",
                                                      link_ticket_ids: [ twin.id ])

      expect(flash[:notice]).to eq(I18n.t("member.tickets.created"))
    end

    it "dedup_ack=create senza motivazione non crea e ripresenta il confronto con l'errore VISIBILE in pagina" do
      expect {
        post member_tickets_path, params: create_params(dedup_ack: "create", dedup_reason: "")
      }.not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"ticket-comparison\"")
      # Regressione del report "non accade nulla": l'errore deve essere un banner IN PAGINA, non solo
      # il toast in basso a destra (invisibile dopo la chiusura del dialog).
      expect(response.body).to include("data-test=\"ticket-comparison-error\"")
      expect(response.body).to include(I18n.t("member.tickets.comparison.errors.reason_required"))
      # Il dialog "Crea comunque" si riapre da solo (open-value) sull'esito fallito → l'utente ci ritorna.
      expect(response.body).to include('data-ui--dialog-open-value="true"')
    end

    it "la pagina di confronto arma il required sulla motivazione e lascia passare il link (formnovalidate)" do
      post member_tickets_path, params: create_params

      expect(response).to have_http_status(:unprocessable_content)
      # Il caso più comune del bug (motivo vuoto) è bloccato a monte dal browser.
      expect(response.body).to match(/name="dedup_reason"[^>]*required/)
      # Il submit "Crea e collega" bypassa la validazione: altrimenti il required nascosto nel dialog
      # chiuso lo bloccherebbe in silenzio (gotcha Chrome sui campi non focusabili).
      expect(response.body).to match(/name="dedup_ack" value="link" formnovalidate/)
    end

    it "opens both outcome dialogs in the standard modal shell, with the confirm in the header (F24)" do
      post member_tickets_path, params: create_params

      page = Nokogiri::HTML(response.body)
      { "ticket-comparison-create-modal" => "ticket-comparison-create-submit",
        "ticket-comparison-link-modal" => "ticket-comparison-link-submit" }.each do |dialog_id, submit_id|
        dialog = page.at_css("dialog[data-test='#{dialog_id}']")
        expect(dialog["class"]).to include("dark:bg-zinc-950")
        expect(dialog.at_css("header [data-test='#{submit_id}']")).to be_present
        # The submit still belongs to the comparison form: the dialog draws no form of its own.
        expect(dialog.css("form")).to be_empty
      end
    end

    it "dedup_ack=link crea, collega e commenta il preesistente" do
      expect {
        post member_tickets_path, params: create_params(
          dedup_ack: "link", link_ticket_ids: [ twin.id ], link_kind: "duplicate",
          link_comment: "Segnalato di nuovo oggi"
        )
      }.to change(Connections::TicketLink, :count).by(1)
       .and change(Ticketing::Ticket, :count).by(1)

      expect(twin.comments.last.body).to eq("Segnalato di nuovo oggi")
      follow_redirect!
      expect(response.body).to include(twin.code)
    end

    it "dedup_ack=link con target di un progetto non visibile non crea nulla (anti-BOLA)" do
      hidden_project = create(:project, organization: org)
      hidden = create(:ticket, organization: org, project: hidden_project)

      expect {
        post member_tickets_path, params: create_params(
          dedup_ack: "link", link_ticket_ids: [ hidden.id ], link_kind: "duplicate"
        )
      }.not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
