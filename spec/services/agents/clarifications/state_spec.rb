# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Clarifications::State do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  def round(answered: false, questions: [ "Prima domanda?" ])
    clarification = create(:agent_clarification, workflow:, questions:)
    clarification.update!(answered_at: Time.current, response_snapshot: "1. Sì") if answered
    clarification
  end

  it "senza lavorazione non c'è niente da aspettare" do
    snapshot = described_class.call(workflow: nil)

    expect(snapshot.state).to eq("ready")
    expect(snapshot.cycles).to be_zero
    expect(snapshot.rounds).to be_empty
  end

  it "senza domande la lavorazione è pronta" do
    expect(described_class.call(workflow:).state).to eq("ready")
  end

  it "una domanda senza risposta mette in attesa" do
    round

    snapshot = described_class.call(workflow:)
    expect(snapshot.state).to eq("waiting")
    expect(snapshot.cycles).to eq(1)
    expect(snapshot.has_reply).to be(false)
  end

  it "risposto all'ultimo giro, la lavorazione torna pronta" do
    round(answered: true)

    snapshot = described_class.call(workflow:)
    expect(snapshot.state).to eq("ready")
    expect(snapshot.has_reply).to be(true)
  end

  # Una risposta VECCHIA non dice niente sul giro in corso: un lettore che la leggesse come "ha
  # risposto" riprenderebbe una lavorazione che sta ancora aspettando.
  it "un giro nuovo senza risposta batte la risposta del giro precedente" do
    round(answered: true)
    round

    snapshot = described_class.call(workflow:)
    expect(snapshot.state).to eq("waiting")
    expect(snapshot.cycles).to eq(2)
    expect(snapshot.has_reply).to be(false)
  end

  # "Ferma e serve una persona" è già `blocked_at` (CYRA-218), con la sua UI e il suo "riprova": lo
  # stato di arresto è uno solo, non due da tenere allineati.
  it "una lavorazione ferma risulta escalata" do
    round
    workflow.update!(blocked_at: Time.current, blocked_phase: "triage", blocked_kind: "attempt_limit", blocked_reason: "review_limit: triage")

    expect(described_class.call(workflow:).state).to eq("escalated")
  end

  it "numera i giri in ordine cronologico con le loro domande" do
    round(questions: [ "Prima?" ], answered: true)
    round(questions: [ "Seconda?", "Terza?" ])

    rounds = described_class.call(workflow:).rounds
    expect(rounds.map(&:cycle)).to eq([ 1, 2 ])
    expect(rounds.first.questions).to eq([ "Prima?" ])
    expect(rounds.first.response).to eq("1. Sì")
    expect(rounds.last.questions).to eq([ "Seconda?", "Terza?" ])
    expect(rounds.last.answered_at).to be_nil
  end

  # CYRA-784 — la sorgente è una sola: le righe di primo livello. La forma servita ai due repository
  # esterni non è cambiata di un byte, ed è questo che queste prove tengono fermo.
  describe "sorgente delle domande" do
    let(:author) do
      create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
    end

    def question_row(clarification, body, position:)
      Ticketing::Question.create!(
        ticket:, round_id: clarification.id, body:, position:, blocking: true, origin: :agent,
        author:
      )
    end

    def question_answer(question, body)
      riga = Ticketing::Answer.create!(question:, author:, body:)
      question.update!(answered_at: Time.current, resolved_answer: riga)
      riga
    end

    it "legge le domande dalle righe di primo livello" do
      create(:agent_clarification, workflow:, questions: [ "Dalla riga?" ])

      expect(described_class.call(workflow:).rounds.first.questions).to eq([ "Dalla riga?" ])
    end

    # L'archivio jsonb era l'unica altra strada da cui potevano arrivare: senza righe un giro non ha
    # domande, e nessun campo storico le rimette.
    it "un giro senza righe non ha domande" do
      create(:agent_clarification, workflow:, questions: [ "Sparita?" ]).questions.delete_all

      expect(described_class.call(workflow:).rounds.first.questions).to be_empty
    end

    # Il lettore esterno rifiuta in blocco un giro con più di tre domande, e con esso l'intera coda.
    it "non serve mai più di tre domande per giro" do
      clarification = create(:agent_clarification, workflow:, questions: [ "Una?" ])
      4.times { |i| question_row(clarification, "Domanda #{i}?", position: i + 2) }

      expect(described_class.call(workflow:).rounds.first.questions.size).to eq(3)
    end

    it "serve la risposta storica verbatim, senza ricomporla" do
      clarification = create(:agent_clarification, workflow:, questions: [ "Quale?" ])
      clarification.update!(answered_at: Time.current, response_snapshot: "Quella di sinistra.")
      clarification.questions.first.then { |q| question_answer(q, "Un altro testo.") }

      expect(described_class.call(workflow:).rounds.first.response).to eq("Quella di sinistra.")
    end

    it "compone la risposta nella forma numerata di prima quando lo storico non ce l'ha" do
      clarification = create(:agent_clarification, workflow:, questions: [ "Prima?", "Seconda?" ])
      clarification.update!(answered_at: Time.current)
      question_answer(clarification.questions.first, "Sì")
      question_answer(clarification.questions.second, "No")

      expect(described_class.call(workflow:).rounds.first.response).to eq("1. Sì\n2. No")
    end
  end
end
