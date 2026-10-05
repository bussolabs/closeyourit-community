# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ShowTicket do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "555").tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org, key: "DRRA") }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  it "mostra code, stato e priorità di un ticket visibile" do
    ticket = create(:ticket, :plain_bug, organization: org, project: project)
    described_class.call(account: account, chat_id: "555", code: ticket.code)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: include(ticket.code).and(include(ticket.status.label))))
  end

  it "mostra l'assegnatario quando presente" do
    assignee = create(:account, name: "Mara").tap { |a| create(:membership, account: a, organization: org, role: :member) }
    ticket = create(:ticket, :plain_bug, organization: org, project: project, assignee: assignee)
    described_class.call(account: account, chat_id: "555", code: ticket.code)
    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include("Mara")))
  end

  it "code inesistente → messaggio d'errore (nessuna eccezione)" do
    result = described_class.call(account: account, chat_id: "555", code: "DRRA-9999")
    expect(result).to be_err
    expect(Telegram::Send).to have_received(:call)
  end

  it "code mancante → messaggio d'uso (R422-TELEGRAM-007)" do
    result = described_class.call(account: account, chat_id: "555", code: nil)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TELEGRAM-007")
  end
end
