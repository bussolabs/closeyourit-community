require "rails_helper"

RSpec.describe Ticketing::Questions::Answer, type: :service do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:question) { create(:ticket_question, ticket: ticket, organization: organization) }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  it "chiude la domanda e la lega alla risposta che l'ha chiusa" do
    result = described_class.call(question: question, author: author, body: "Sì, va bene.")

    expect(result).to be_ok
    expect(question.reload.answered_at).to be_present
    expect(question.resolved_answer).to eq(result.value)
  end

  it "scrive una riga di cronologia" do
    expect { described_class.call(question: question, author: author, body: "Sì.") }
      .to change { ticket.events.where(action: "question_answered").count }.by(1)
  end

  # È il punto del ticket: prima la risposta era il primo commento umano arrivato dopo.
  it "non tocca le altre domande aperte dello stesso ticket" do
    altra = create(:ticket_question, ticket: ticket, organization: organization)

    described_class.call(question: question, author: author, body: "Sì.")

    expect(altra.reload.answered_at).to be_nil
  end

  # Il momento in cui una domanda ha smesso di aspettare è uno solo, ed è il primo.
  it "una seconda risposta resta scritta ma non sposta il momento della chiusura" do
    prima = described_class.call(question: question, author: author, body: "Sì.").value
    question.reload
    chiusura = question.answered_at

    seconda = described_class.call(question: question, author: author, body: "Anzi, no.")

    expect(seconda).to be_ok
    expect(question.reload.answered_at).to eq(chiusura)
    expect(question.resolved_answer).to eq(prima)
    expect(question.answers.count).to eq(2)
  end

  # `answered_at` è l'autorità, non la chiave esterna: la chiave cade a NULL da sé.
  it "cancellare la risposta non riapre la domanda" do
    answer = described_class.call(question: question, author: author, body: "Sì.").value

    answer.destroy

    expect(question.reload.answered_at).to be_present
    expect(question.resolved_answer_id).to be_nil
    expect(question).not_to be_open
  end

  it "rifiuta una risposta a una domanda ritirata" do
    question.update!(closed_at: Time.current)

    result = described_class.call(question: question, author: author, body: "Sì.")

    expect(result).to be_err
    expect(result.error.code).to eq("R409-QUESTION-001")
  end

  it "rifiuta una risposta vuota senza scrivere niente" do
    result = nil
    expect { result = described_class.call(question: question, author: author, body: "  ") }
      .not_to change(Ticketing::Answer, :count)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-QUESTION-002")
    expect(question.reload.answered_at).to be_nil
  end
end
