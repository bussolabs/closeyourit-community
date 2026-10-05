# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Clarifications::Ask do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:author) do
    Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
  end
  let(:attempt) do
    create(:agent_attempt, organization:, workflow:, service_account: author, phase: "triage")
  end

  it "registra le domande nel record e sul ticket lascia una riga di servizio" do
    result = described_class.call(workflow:, attempt:, author:,
                                  questions: [ "Cosa deve vedere chi non ha accesso?" ])

    expect(result).to be_ok
    expect(result.value.questions.map(&:body)).to eq([ "Cosa deve vedere chi non ha accesso?" ])
    comment = ticket.comments.sole
    expect(comment.author).to eq(author)
    expect(comment).to be_kind_service
    expect(comment.body).not_to include("Cosa deve vedere chi non ha accesso?")
    expect(result.value.question_comment).to eq(comment)
  end

  # Il caso che rendeva il tetto irrilasciabile: `create!` (bang) dentro la transazione di
  # Agents::Attempts::Deliver con un corpo di ~716 caratteri → RecordInvalid → 500 su attempt_results,
  # consegna persa e ticket fermo in progress. Il corpo ora ha lunghezza fissa: le domande non ci
  # entrano più, quindi non possono più farlo sfondare.
  it "non solleva con tre domande da 180 caratteri" do
    questions = Array.new(3) { |i| "Domanda #{i} #{"x" * 160}?" }

    expect do
      described_class.call(workflow:, attempt:, author:, questions:)
    end.not_to raise_error
  end

  # In OGNI lingua, non solo in quella di default: la riga è tradotta e una traduzione più lunga la
  # farebbe sfondare in produzione per i soli utenti di quella lingua — cioè in un caso su due, e mai
  # in sviluppo.
  it "sta sotto il tetto dei commenti in ogni lingua" do
    questions = Array.new(3) { |i| "Domanda #{i} #{"x" * 160}?" }

    App::Constants::LOCALES.each do |locale|
      ticket.reporter.update!(locale: locale)
      described_class.call(workflow:, attempt:, author:, questions:)

      body = ticket.comments.reload.last.body
      expect(body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS,
                             "riga di servizio troppo lunga in #{locale}: #{body.length} caratteri"
    end
  end

  # CYRA-784 — il marker era il contratto che skill e automator rileggevano dal testo del commento.
  # Ora lo stato lo chiedono a `GET .../clarifications`, e la riga di servizio torna a essere solo una
  # frase per una persona. Una riga di servizio con dentro un commento HTML è rumore che il lettore
  # umano vede e non capisce.
  it "non lascia nessuna riga di servizio nascosta nel commento" do
    described_class.call(workflow:, attempt:, author:, questions: [ "Prima domanda?" ])
    described_class.call(workflow:, attempt:, author:, questions: [ "Seconda domanda?" ])

    expect(ticket.comments.map(&:body).join("\n")).not_to include("<!--")
  end

  # La Clarification nasce PRIMA del commento: Ticketing::AddComment aggancia una risposta solo a una
  # domanda più vecchia di essa. Nell'ordine opposto la prima risposta resterebbe orfana e la
  # lavorazione non ripartirebbe.
  it "crea il record prima del commento" do
    clarification = described_class.call(workflow:, attempt:, author:, questions: [ "Prima?" ]).value

    expect(clarification.created_at).to be <= ticket.comments.sole.created_at
  end

  it "scrive nella lingua di chi ha aperto il ticket" do
    ticket.reporter.update!(locale: "en")

    described_class.call(workflow:, attempt:, author:, questions: [ "What happens on logout?" ])

    expect(ticket.comments.sole.body).to start_with("An answer is needed")
  end

  # CYRA-784 — le domande vivono in un posto solo: le righe di primo livello. Il jsonb di
  # `agents_clarifications` era l'archivio vecchio, e finché esisteva le stesse domande stavano in due
  # posti che un giorno potevano divergere.
  it "scrive le domande solo come righe di primo livello" do
    described_class.call(workflow:, attempt:, author:, questions: [ "Prima?", "Seconda?" ])

    expect(Agents::Clarification.column_names).not_to include("questions")
    righe = ticket.questions.order(:position)
    expect(righe.map(&:body)).to eq([ "Prima?", "Seconda?" ])
    expect(righe.map(&:round_id).uniq).to eq([ workflow.clarifications.sole.id ])
  end

  it "non lascia un commento orfano se il record non è valido" do
    expect do
      expect { described_class.call(workflow:, attempt:, author:, questions: []) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end.not_to change(ticket.comments, :count)
  end
end
