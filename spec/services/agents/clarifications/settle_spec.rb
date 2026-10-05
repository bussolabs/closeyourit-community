require "rails_helper"

RSpec.describe Agents::Clarifications::Settle, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  def giro(questions:)
    create(:agent_clarification, workflow:, questions:)
  end

  it "risponde alla domanda che nomina e chiude il giro" do
    clarification = giro(questions: [ "Prima?", "Seconda?" ])

    result = described_class.call(clarification:, author:, answers: [ "Sì", "No" ])

    expect(result).to be_ok
    righe = clarification.questions.order(:position)
    expect(righe.map { |q| q.answers.first&.body }).to eq([ "Sì", "No" ])
    expect(righe.map(&:answered_at)).to all(be_present)
    expect(clarification.reload.answered_at).to be_present
    expect(clarification.response_snapshot).to eq("1. Sì\n2. No")
  end

  it "rimette la lavorazione in coda al triage" do
    clarification = giro(questions: [ "Quale?" ])
    workflow.update!(triage_started_at: Time.current, triage_requested_at: nil)

    described_class.call(clarification:, author:, answers: [ "Quella." ])

    expect(workflow.reload.triage_requested_at).to be_present
    expect(workflow.triage_started_at).to be_nil
  end

  it "i buchi restano buchi: chi risponde a una sola domanda non ne inventa altre" do
    clarification = giro(questions: [ "Prima?", "Seconda?" ])

    described_class.call(clarification:, author:, answers: [ nil, "Solo la seconda." ])

    righe = clarification.questions.order(:position)
    expect(righe.first.answered_at).to be_nil
    expect(righe.second.answered_at).to be_present
    expect(clarification.reload.response_snapshot).to eq("2. Solo la seconda.")
  end

  # CYRA-784 — un giro senza nemmeno una riga di domanda non ha niente a cui appendere la risposta.
  # Ci si arrivava dall'archivio jsonb, che chiudeva il giro lasciando la risposta senza domanda; ora
  # l'archivio non c'è più e il caso è un errore dichiarato, non un giro chiuso a vuoto.
  it "un giro senza domande non ha niente da chiudere" do
    clarification = create(:agent_clarification, workflow:, questions: [ "Storica?" ])
    clarification.questions.delete_all

    result = described_class.call(clarification:, author:, answers: [ "Risposta." ])

    expect(result).to be_err
    expect(result.error.code).to eq("R422-CLARIFICATION-001")
    expect(clarification.reload.answered_at).to be_nil
  end

  # Quel testo lo legge una persona dall'altra parte: un «1. » davanti non è una numerazione, è rumore.
  it "una risposta che copre il giro non viene numerata" do
    clarification = giro(questions: [ "Prima?", "Seconda?" ])

    described_class.call(clarification:, author:, answers: [ "Vale per entrambe.", "Vale per entrambe." ],
                         covers_round: true)

    expect(clarification.reload.response_snapshot).to eq("Vale per entrambe.")
    expect(clarification.questions.flat_map(&:answers)).to all(be_covers_round)
  end

  it "senza nemmeno una risposta non tocca niente" do
    clarification = giro(questions: [ "Prima?" ])

    result = described_class.call(clarification:, author:, answers: [ "  " ])

    expect(result).to be_err
    expect(result.error.code).to eq("R422-CLARIFICATION-001")
    expect(clarification.reload.answered_at).to be_nil
  end

  it "su un ticket concluso registra la risposta ma non rimette in coda niente" do
    clarification = giro(questions: [ "Prima?" ])
    ticket.update!(status: create(:ticket_status, organization:, category: :done))

    result = described_class.call(clarification:, author:, answers: [ "Sì" ])

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-013")
    expect(clarification.reload.answered_at).to be_nil
  end
end
