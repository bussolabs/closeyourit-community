# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::Help do
  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  it "invia il testo di aiuto nella lingua dell'utente" do
    account = create(:account, locale: "it")
    described_class.call(account: account, chat_id: "42")
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(chat_id: "42", text: I18n.t("telegram.help.body", locale: :it)))
  end
end
