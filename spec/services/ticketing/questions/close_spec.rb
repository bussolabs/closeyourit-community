require "rails_helper"

RSpec.describe Ticketing::Questions::Close, type: :service do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }
  let(:question) { create(:ticket_question, :blocking, ticket: ticket, organization: organization) }
  let(:actor) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  it "ritira la domanda segnando chi e quando" do
    result = described_class.call(question: question, actor: actor)

    expect(result).to be_ok
    expect(question.reload.closed_at).to be_present
    expect(question.closed_by).to eq(actor)
    expect(question).not_to be_open
  end

  it "scrive una riga di cronologia" do
    expect { described_class.call(question: question, actor: actor) }
      .to change { ticket.events.where(action: "question_closed").count }.by(1)
  end

  it "è idempotente: ritirarla due volte non cambia niente e non raddoppia la cronologia" do
    described_class.call(question: question, actor: actor)
    ritiro = question.reload.closed_at

    expect { described_class.call(question: question, actor: actor) }
      .not_to change { ticket.events.where(action: "question_closed").count }
    expect(question.reload.closed_at).to eq(ritiro)
  end

  it "rifiuta di ritirare una domanda che ha già una risposta" do
    question.update!(answered_at: Time.current)

    result = described_class.call(question: question, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-QUESTION-002")
    expect(question.reload.closed_at).to be_nil
  end
end
