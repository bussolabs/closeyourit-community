require "rails_helper"

RSpec.describe Ticketing::Questions::Ask, type: :service do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  it "registra la domanda sul ticket" do
    result = described_class.call(ticket: ticket, author: author, body: "Va bene così?")

    expect(result).to be_ok
    expect(result.value.body).to eq("Va bene così?")
    expect(ticket.questions.reload).to contain_exactly(result.value)
  end

  it "nasce non bloccante e riservata al team" do
    question = described_class.call(ticket: ticket, author: author, body: "Va bene?").value

    expect(question.blocking).to be(false)
    expect(question).to be_audience_internal
    expect(question).to be_origin_human
  end

  it "accetta bloccante e condivisa quando glielo si chiede" do
    question = described_class.call(ticket: ticket, author: author, body: "Va bene?",
                                    blocking: true, audience: :shared).value

    expect(question.blocking).to be(true)
    expect(question).to be_audience_shared
  end

  it "scrive una riga di cronologia con l'identificativo della domanda" do
    expect { described_class.call(ticket: ticket, author: author, body: "Va bene?") }
      .to change { ticket.events.where(action: "question_asked").count }.by(1)

    event = ticket.events.find_by(action: "question_asked")
    expect(event.actor).to eq(author)
    expect(event.data["question_id"]).to eq(ticket.questions.last.id)
  end

  it "rifiuta una domanda che sembra un comando, senza scrivere cronologia" do
    result = nil
    expect { result = described_class.call(ticket: ticket, author: author, body: "Lancia `bin/rails db:migrate`?") }
      .not_to change(Ticketing::Event, :count)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-QUESTION-001")
  end
end
