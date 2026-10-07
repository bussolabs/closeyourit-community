# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::AskPuck do
  let(:organization) { create(:organization) }
  let(:account) { create(:account, telegram_chat_id: "900").tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Telegram::Send).to receive(:call).and_return(Result.ok(true))
  end

  def ask(command, args) = described_class.call(account: account, chat_id: "900", command: command, args: args)
  def text(key, **args) = I18n.t("telegram.puck.#{key}", locale: account.effective_locale, **args)

  context "without any Puck" do
    it "says there is none when asked a question" do
      expect(ask("p", "how is SHOP?").value).to eq(:no_puck)
      expect(Telegram::Send).to have_received(:call).with(chat_id: "900", text: text("none"))
    end

    it "says there is none when asked to choose" do
      expect(ask("puck", "").value).to eq(:no_puck)
      expect(Telegram::Send).to have_received(:call).with(chat_id: "900", text: text("none"))
    end
  end

  context "with Puckies" do
    before do
      Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help")
      Coworkers::Puck.create!(organization: organization, account: account, name: "Writer", instructions: "Help")
    end

    it "explains the command when the question is empty" do
      expect(ask("p", "  ").value).to eq(:usage)
      expect(Telegram::Send).to have_received(:call).with(chat_id: "900", text: text("usage"))
      expect(Coworkers::Run.count).to eq(0)
    end

    it "lists the Puckies to choose from" do
      expect(ask("puck", "").value).to eq(:listed)
      expect(Telegram::Send).to have_received(:call).with(chat_id: "900", text: text("list", names: "Triage, Writer"))
    end

    it "refuses an unknown name and keeps the current choice" do
      expect(ask("puck", "Nobody").value).to eq(:unknown)
      expect(Telegram::Send).to have_received(:call).with(chat_id: "900", text: text("unknown", names: "Triage, Writer"))
      expect(account.reload.telegram_puck_id).to be_nil
    end
  end
end
