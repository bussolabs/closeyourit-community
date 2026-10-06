# frozen_string_literal: true

require "rails_helper"

# CYRA-782 — la scheda Domande. Si chiede, si risponde alla domanda che si nomina, si ritira una
# domanda superata dai fatti. La discussione è tornata a essere conversazione.
RSpec.describe "Member ticket questions", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:membro) do
    create(:account).tap do |account|
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
  end
  let(:gestore) do
    create(:account).tap do |account|
      create(:membership, :owner, organization:, account:)
      create(:project_membership, account:, project:)
    end
  end

  def entra(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def domanda(**attributi)
    Ticketing::Question.create!(ticket:, author: membro, body: "Quale strada?", **attributi)
  end

  describe "la scheda" do
    before { entra(membro) }

    it "si apre e mostra il posto dove chiedere" do
      get member_ticket_path(ticket, tab: "questions")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.tickets.questions.title"))
      expect(response.body).to include(member_ticket_questions_path(ticket))
    end

    it "da vuota lo dice invece di mostrare una lista vuota" do
      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include(I18n.t("member.tickets.questions.empty_title"))
    end

    it "mostra domanda e risposta accanto" do
      riga = domanda
      Ticketing::Questions::Answer.call(question: riga, author: membro, body: "Quella di sinistra.")

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include("Quale strada?").and include("Quella di sinistra.")
    end

    it "marks a question asked by the automation, and only that one" do
      from_work = domanda(origin: :agent, body: "Which rounding?")
      from_person = domanda(body: "Who reviews?")

      get member_ticket_path(ticket, tab: "questions")

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-test='ticket-question-#{from_work.id}'] [data-test='ticket-question-from-work']")).to be_present
      expect(page.at_css("[data-test='ticket-question-#{from_person.id}'] [data-test='ticket-question-from-work']")).to be_nil
    end

    it "tells how many settled questions came from the automation" do
      domanda(origin: :agent, body: "Which rounding?").update!(closed_at: Time.current)
      domanda(body: "Who reviews?").update!(closed_at: Time.current)

      get member_ticket_path(ticket, tab: "questions")

      summary = Nokogiri::HTML(response.body).at_css("[data-test='ticket-questions-settled'] summary")
      expect(summary.at_css("[data-test='ticket-questions-settled-from-work']").text)
        .to include(I18n.t("member.tickets.questions.settled_from_work", count: 1))
    end

    # Il pallino conta le domande aperte, ed è la sola cosa della pagina che aspetta una persona.
    it "il pallino sulla striscia conta le domande aperte" do
      domanda
      domanda(body: "E l'altra?")

      get member_ticket_path(ticket)

      expect(response.body).to include(I18n.t("member.tickets.automation.questions.pending", count: 2))
    end
  end

  # Chi apre il dettaglio deve sapere che il ticket è fermo, non scoprirlo aprendo la scheda giusta.
  describe "il ticket fermo" do
    before { entra(membro) }

    # Una GET per esempio: più richieste nello stesso esempio fanno leggere al guard N+1 i lookup di
    # sessione come una lettura a raffica, ed è una trappola già annotata in questo repository.
    %w[detail automation discussion].each do |scheda|
      it "lo dichiara in testa alla scheda #{scheda}" do
        domanda(blocking: true)

        get member_ticket_path(ticket, tab: scheda)

        expect(response.body).to include(I18n.t("member.tickets.questions.blocked", count: 1))
      end
    end

    it "shows the notice in the bottom-right toast stack, not inside the page" do
      domanda(blocking: true)

      get member_ticket_path(ticket)

      page = Nokogiri::HTML(response.body)
      expect(page.css("[data-test='ticket-blocked-by-questions']").size).to eq(1)
      expect(page.at_css("[data-test='flash-container'] [data-test='ticket-blocked-by-questions']")).to be_present
      expect(page.css("[data-test='flash-container']").size).to eq(1)
    end

    it "non lo dichiara per una domanda che non blocca" do
      domanda(blocking: false)

      get member_ticket_path(ticket)

      expect(response.body).not_to include(I18n.t("member.tickets.questions.blocked", count: 1))
    end

    it "smette di dichiararlo appena arriva la risposta" do
      riga = domanda(blocking: true)
      Ticketing::Questions::Answer.call(question: riga, author: membro, body: "Ecco.")

      get member_ticket_path(ticket)

      expect(response.body).not_to include(I18n.t("member.tickets.questions.blocked", count: 1))
    end
  end

  describe "fare una domanda" do
    before { entra(membro) }

    it "la registra e riporta alla scheda" do
      expect { post member_ticket_questions_path(ticket), params: { body: "Serve il backfill?" } }
        .to change { ticket.questions.count }.by(1)

      expect(response).to redirect_to(member_ticket_path(ticket, tab: "questions"))
      expect(ticket.questions.last.body).to eq("Serve il backfill?")
    end

    it "non scrive niente nella discussione" do
      expect { post member_ticket_questions_path(ticket), params: { body: "Serve il backfill?" } }
        .not_to change { ticket.comments.count }
    end

    # Marcare una domanda bloccante ferma la coda degli agenti: è una leva sul lavoro, e chi non può
    # modificare il ticket non la tira. La domanda si pone lo stesso — semplicemente non blocca.
    it "chi non può modificare il ticket non può renderla bloccante" do
      post member_ticket_questions_path(ticket), params: { body: "Serve?", blocking: "1" }

      expect(ticket.questions.last.blocking).to be(false)
    end

    it "chi può modificare il ticket sì" do
      entra(gestore)

      post member_ticket_questions_path(ticket), params: { body: "Serve?", blocking: "1" }

      expect(ticket.questions.last.blocking).to be(true)
    end

    it "rifiuta una domanda che sembra un comando e lo dice" do
      expect { post member_ticket_questions_path(ticket), params: { body: "Lancia `bin/rails db:migrate`?" } }
        .not_to change { ticket.questions.count }

      expect(flash[:alert]).to be_present
    end
  end

  describe "rispondere" do
    before { entra(membro) }

    it "lega la risposta alla domanda che nomina" do
      riga = domanda
      altra = domanda(body: "E l'altra?")

      post member_ticket_question_answers_path(ticket, riga), params: { body: "Questa qui." }

      expect(riga.reload.answered_at).to be_present
      expect(riga.answers.first.body).to eq("Questa qui.")
      expect(altra.reload.answered_at).to be_nil
    end

    it "shows the proposed answers as buttons, the recommended one with its reason" do
      riga = domanda
      riga.update_column(:options, [ { "label" => "Solo mostrato", "recommended" => true, "reason" => "Nessuno ha chiesto email." },
                                     { "label" => "Email" } ])

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include(%(data-test="ticket-question-choice-#{riga.id}-1"))
      expect(response.body).to include(%(data-test="ticket-question-choice-#{riga.id}-2"))
      expect(response.body).to include("Nessuno ha chiesto email.")
    end

    # CYRA-1033 — a click on a proposed answer.
    it "answers with the clicked proposed answer" do
      riga = domanda
      riga.update_column(:options, [ { "label" => "Solo mostrato" }, { "label" => "Email" } ])

      post member_ticket_question_answers_path(ticket, riga), params: { choice: 1 }

      expect(riga.reload.resolved_answer).to have_attributes(body: "Solo mostrato", choice_index: 1)
    end
  end

  describe "ritirare una domanda" do
    it "the manager withdraws a question they asked" do
      entra(gestore)
      riga = domanda(blocking: true, author: gestore)

      patch member_ticket_question_closure_path(ticket, riga), params: { confirm: 1 }

      expect(riga.reload.closed_at).to be_present
      expect(riga.closed_by).to eq(gestore)
    end

    it "nobody withdraws a question someone else asked, and the button is not offered" do
      entra(gestore)
      riga = domanda(blocking: true)

      get member_ticket_path(ticket, tab: "questions")
      expect(response.body).not_to include("ticket-question-close-#{riga.id}")

      patch member_ticket_question_closure_path(ticket, riga), params: { confirm: 1 }

      expect(riga.reload.closed_at).to be_nil
    end

    it "chi non può modificare il ticket non la ritira" do
      entra(membro)
      riga = domanda(blocking: true)

      patch member_ticket_question_closure_path(ticket, riga), params: { confirm: 1 }

      expect(riga.reload.closed_at).to be_nil
    end
  end

  describe "cancellare una domanda" do
    it "l'autore cancella la propria" do
      entra(membro)
      riga = domanda

      expect { delete member_ticket_question_path(ticket, riga), params: { confirm: 1 } }
        .to change { ticket.questions.count }.by(-1)
    end

    it "un altro membro non cancella quella di un collega" do
      riga = domanda
      altro = create(:account).tap do |account|
        create(:membership, account:, organization:, role: :member)
        create(:project_membership, account:, project:)
      end
      entra(altro)

      expect { delete member_ticket_question_path(ticket, riga), params: { confirm: 1 } }
        .not_to change { ticket.questions.count }
    end
  end

  # Anti-BOLA: un ticket fuori dalla visibilità di chi guarda non esiste, non è vietato.
  describe "un ticket che non vedo" do
    it "risponde 404, mai 403" do
      estraneo = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      entra(estraneo)

      get member_ticket_path(ticket, tab: "questions")

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-848 — la distinzione «riservata al gruppo di lavoro / condivisa col cliente» veniva salvata
  # e mai applicata in lettura: il cliente vedeva tutto, compreso il piano di lavoro delle domande
  # poste dagli automi, che nascono riservate.
  describe "domande riservate e ruolo cliente" do
    let(:cliente) do
      create(:account).tap do |account|
        create(:membership, account:, organization:, role: :customer)
        create(:project_membership, account:, project:)
      end
    end

    before { entra(cliente) }

    it "il cliente vede solo le domande condivise" do
      domanda(body: "Il piano tocca il file dei segreti?")
      domanda(body: "Va bene consegnare giovedì?", audience: :shared)

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include("Va bene consegnare giovedì?")
      expect(response.body).not_to include("Il piano tocca il file dei segreti?")
    end

    it "nessun contatore rivela le riservate" do
      domanda
      domanda(body: "E questa?")

      get member_ticket_path(ticket, tab: "questions")

      conteggio = Nokogiri::HTML(response.body).at_css('[data-test="ticket-questions-open-count"]')
      expect(conteggio.text).to include("0")
      expect(response.body).to include(I18n.t("member.tickets.questions.empty_title"))
    end

    it "una domanda bloccante riservata non annuncia al cliente che il ticket è fermo" do
      domanda(blocking: true)

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).not_to include(I18n.t("member.tickets.questions.blocked", count: 1))
    end

    it "al gruppo di lavoro le riservate restano visibili" do
      domanda(body: "Il piano tocca il file dei segreti?")
      entra(gestore)

      get member_ticket_path(ticket, tab: "questions")

      expect(response.body).to include("Il piano tocca il file dei segreti?")
    end

    it "il cliente non può rispondere a una domanda riservata" do
      riservata = domanda

      post member_ticket_question_answers_path(ticket, riservata), params: { body: "Provo lo stesso." }

      expect(riservata.answers.count).to eq(0)
    end
  end
end
