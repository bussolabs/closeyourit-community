require "rails_helper"

RSpec.describe Ticketing::AddComment do
  describe "tetto di 240 caratteri" do
    let(:organization) { create(:organization) }
    let(:ticket) { create(:ticket, organization: organization, with_agent_workflow: true) }
    let(:author) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end

    it "rifiuta con un codice DEDICATO che indirizza al resoconto" do
      body = "x" * (Ticketing::Constants::COMMENT_MAX_CHARS + 1)

      result = nil
      # Locale esplicito: la suite gira in inglese, ma il messaggio deve nominare il tetto E indicare
      # dove va il testo lungo in entrambe le lingue.
      I18n.with_locale(:it) do
        expect { result = described_class.call(ticket: ticket, author: author, params: { body: body }) }
          .not_to change(Ticketing::Comment, :count)
      end

      expect(result).to be_err
      expect(result.error.code).to eq("R422-COMMENT-002")
      expect(result.error.message).to include("240").and include("resoconto")
      expect(result.error.details[:body]).to be_present
    end

    it "lascia il codice generico agli altri errori" do
      result = described_class.call(ticket: ticket, author: author, params: { body: "   " })

      expect(result.error.code).to eq("R422-COMMENT-001")
    end
  end

  let(:org) { create(:organization) }
  let(:ticket) { create(:ticket, organization: org, with_agent_workflow: true) }
  let(:author) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :member) }
  end

  it "crea un commento con autore l'account fornito e ritorna ok" do
    result = nil
    expect do
      result = described_class.call(ticket: ticket, author: author, params: { body: "Looks broken" })
    end.to change(Ticketing::Comment, :count).by(1)

    expect(result).to be_ok
    expect(result.value).to be_a(Ticketing::Comment)
    expect(result.value.author).to eq(author)
    expect(result.value.ticket).to eq(ticket)
    expect(result.value.body).to eq("Looks broken")
  end

  it "allega i file forniti" do
    result = described_class.call(
      ticket: ticket, author: author,
      params: { body: "with file", files: [ { io: StringIO.new("x"), filename: "a.png", content_type: "image/png" } ] }
    )

    expect(result).to be_ok
    expect(result.value.files).to be_attached
  end

  it "ritorna un errore con codice R422-COMMENT-001 su body vuoto" do
    result = nil
    expect do
      result = described_class.call(ticket: ticket, author: author, params: { body: "   " })
    end.not_to change(Ticketing::Comment, :count)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-COMMENT-001")
    expect(result.error.details).to be_present
  end

  it "espone un messaggio i18n pulito (niente 'translation missing') su un allegato non ammesso" do
    result = described_class.call(
      ticket: ticket, author: author,
      params: { body: "bad file", files: [ { io: File.open(Rails.root.join("spec/fixtures/files/diagram.svg")), filename: "spoof.png", content_type: "image/png" } ] }
    )

    expect(result).to be_err
    expect(result.error.message).not_to match(/translation missing/i)
    expect(result.error.message).to eq(I18n.t("member.tickets.comments.errors.invalid"))
  end

  it "non registra alcun Ticketing::Event (il commento È già la riga della timeline)" do
    expect do
      described_class.call(ticket: ticket, author: author, params: { body: "ciao" })
    end.not_to change(Ticketing::Event, :count)
  end

  it "collega la prima risposta umana al chiarimento e riaccoda subito il triage" do
    workflow = ticket.agent_workflow.tap { |record| record.update!(triage_started_at: 2.minutes.ago) }
    attempt = create(:agent_attempt, workflow:, organization: org)
    # Skill-mode: il server crea la Clarification senza question_comment (la skill ha già postato il commento).
    clarification = create(:agent_clarification,
      workflow:, attempt:, questions: [ "Quale risultato ti aspetti?" ], created_at: 1.minute.ago
    )

    result = described_class.call(ticket:, author:, params: { body: "Deve tornare alla dashboard." })

    expect(result).to be_ok
    expect(clarification.reload).to have_attributes(
      response_comment: result.value, response_snapshot: "Deve tornare alla dashboard.", answered_at: be_present
    )
    expect(workflow.reload.triage_started_at).to be_nil
    expect(workflow.triage_requested_at).to be_present
  end

  it "non usa un commento automatico come risposta a un chiarimento" do
    workflow = ticket.agent_workflow.tap { |record| record.update!(triage_started_at: Time.current) }
    attempt = create(:agent_attempt, workflow:, organization: org)
    clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Serve una scelta?" ],
                                                   created_at: 1.minute.ago)
    service = create(:account, :service)
    create(:membership, account: service, organization: org)

    described_class.call(ticket:, author: service, params: { body: "Risposta del bot" })

    expect(clarification.reload.response_comment).to be_nil
  end

  describe "loop di collaborazione (watcher + menzioni)" do
    include ActiveJob::TestHelper

    it "auto-iscrive l'autore come watcher (commenter)" do
      described_class.call(ticket: ticket, author: author, params: { body: "ci penso io" })
      expect(ticket.subscriptions.find_by(account: author)&.source_commenter?).to be(true)
    end

    it "auto-iscrive i menzionati membri e accoda il job di notifica" do
      mate = create(:account, handle: "mate").tap { |a| create(:membership, account: a, organization: org, role: :member) }
      expect do
        described_class.call(ticket: ticket, author: author, params: { body: "ping @mate" })
      end.to have_enqueued_job(Ticketing::CommentNotifyJob)
      expect(ticket.subscriptions.find_by(account: mate)&.source_mentioned?).to be(true)
    end

    it "non considera l'autore tra i menzionati (self-mention sottratta)" do
      author.update!(handle: "boss")
      described_class.call(ticket: ticket, author: author, params: { body: "io @boss confermo" })
      expect(ticket.subscriptions.find_by(account: author)&.source_commenter?).to be(true)
    end
  end

  # Discussione live: il commento è già committato (l'action non apre transazioni esterne) → broadcast
  # diretto. Append della bolla + replace dei contatori commenti/watcher, tutti sullo stream del ticket.
  describe "broadcast realtime nella discussione" do
    it "appende il commento e fa il replace dei contatori (commenti + watcher) sullo stream del ticket" do
      stream = Realtime::Streams.ticket(ticket)
      expect(Turbo::StreamsChannel).to receive(:broadcast_append_to).with(
        stream, target: "ticket_timeline_#{ticket.id}", partial: "member/tickets/comment", locals: anything
      )
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        stream, target: "ticket_comments_count_#{ticket.id}", partial: "member/tickets/comments_count", locals: anything
      )
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        stream, target: "#{ActionView::RecordIdentifier.dom_id(ticket)}_watchers",
        partial: "member/tickets/watchers_count", locals: anything
      )
      described_class.call(ticket: ticket, author: author, params: { body: "live!" })
    end

    it "non broadcasta nulla quando il commento è invalido (body vuoto)" do
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_append_to)
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_to)
      described_class.call(ticket: ticket, author: author, params: { body: "   " })
    end

    it "consegna realtime sullo stream del ticket (wiring ActionCable + render end-to-end)" do
      expect do
        described_class.call(ticket: ticket, author: author, params: { body: "ping" })
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket)).at_least(:once)
    end
  end

  # CYRA-781 — l'aggancio dal commento non è più il canale: è la rete per chi risponde da una strada
  # che non sa ancora nominare una domanda (discussione, riga di comando, Telegram). Morde solo su un
  # giro a cui non ha risposto ancora nessuno.
  describe "rete di sicurezza sui commenti" do
    let(:organization) { create(:organization) }
    let(:ticket) { create(:ticket, organization:, with_agent_workflow: true) }
    let(:autore) do
      create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
    end

    def giro_con_riga
      clarification = create(:agent_clarification, workflow: ticket.agent_workflow,
                                                   questions: [ "Quale strada?" ])
      riga = Ticketing::Question.create!(ticket:, round_id: clarification.id, body: "Quale strada?",
                                         position: 1, blocking: true, origin: :agent, author: autore)
      [ clarification, riga ]
    end

    it "un commento chiude un giro a cui non ha risposto nessuno" do
      clarification, riga = giro_con_riga

      described_class.call(ticket:, author: autore, params: { body: "Quella di sinistra." })

      expect(clarification.reload.answered_at).to be_present
      expect(riga.reload.answered_at).to be_present
      expect(riga.answers.first).to be_covers_round
    end

    it "non tocca un giro a cui qualcuno ha già risposto dal canale giusto" do
      clarification, riga = giro_con_riga
      Ticketing::Questions::Answer.call(question: riga, author: autore, body: "Quella di sinistra.")
      chiusura = clarification.reload.answered_at

      described_class.call(ticket:, author: autore, params: { body: "Ah, e un'altra cosa." })

      expect(clarification.reload.answered_at).to eq(chiusura)
      expect(riga.reload.answers.count).to eq(1)
    end

    it "un commento marcato dall'automazione non vale come risposta" do
      clarification, = giro_con_riga

      described_class.call(ticket:, author: autore,
                           params: { body: "Nota. <!-- closeyourit-automation:triage -->" })

      expect(clarification.reload.answered_at).to be_nil
    end
  end
end
