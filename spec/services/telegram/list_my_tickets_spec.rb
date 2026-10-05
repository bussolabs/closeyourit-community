# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ListMyTickets do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "555").tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org, key: "DRRA") }
  let(:open_status) { create(:ticket_status, organization: org, category: :open) }
  let(:done_status) { create(:ticket_status, :done, organization: org) }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  it "elenca i miei ticket aperti (esclude i chiusi e quelli di altri reporter)" do
    mine = create(:ticket, :plain_bug, organization: org, project: project, reporter: account, status: open_status)
    create(:ticket, :plain_bug, organization: org, project: project, reporter: account, status: done_status) # chiuso → escluso
    other = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    create(:ticket, :plain_bug, organization: org, project: project, reporter: other, status: open_status) # non mio → escluso

    described_class.call(account: account, chat_id: "555")

    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include(mine.code)))
  end

  it "nessun ticket mio aperto → messaggio vuoto" do
    described_class.call(account: account, chat_id: "555")
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.ticket.mine_empty", locale: account.effective_locale)))
  end
end
