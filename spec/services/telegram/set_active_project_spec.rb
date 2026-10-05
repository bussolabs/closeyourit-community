# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::SetActiveProject do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "555").tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let!(:project) { create(:project, organization: org, key: "DRRA") }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  it "imposta il progetto attivo per una chiave visibile" do
    result = described_class.call(account: account, chat_id: "555", key: "DRRA")
    expect(result).to be_ok
    expect(account.reload.telegram_project_id).to eq(project.id)
  end

  it "chiave sconosciuta → err, il progetto attivo resta invariato" do
    result = described_class.call(account: account, chat_id: "555", key: "ZZZZ")
    expect(result).to be_err
    expect(account.reload.telegram_project_id).to be_nil
    expect(Telegram::Send).to have_received(:call)
  end

  it "senza chiave → messaggio d'uso (R422-TELEGRAM-008)" do
    result = described_class.call(account: account, chat_id: "555", key: nil)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TELEGRAM-008")
  end
end
