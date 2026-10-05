# frozen_string_literal: true

require "rails_helper"

# CYRA-852 — /start CODICE scritto nel gruppo collega il gruppo con argomenti dell'owner.
RSpec.describe Telegram::LinkGroup do
  let(:organization) { create(:organization, name: "Acme") }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let!(:reply) { stub_request(:post, %r{api.telegram.org/.*/sendMessage}).to_return(status: 200) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
  end

  def link(code, forum: true, chat_id: -100)
    described_class.call(token: code, chat_id: chat_id, title: "Avvisi", forum: forum)
  end

  it "l'owner collega un gruppo con argomenti e il bot lo conferma nel gruppo" do
    code = Accounts::TelegramLinkCode.issue(account: owner, organization: organization)

    expect(link(code)).to be_ok
    group = Alerting::TelegramGroup.find_by!(organization: organization)
    expect(group).to have_attributes(account: owner, chat_id: "-100", title: "Avvisi")
    expect(reply).to have_been_requested
    expect(Accounts::TelegramLinkCode.where(code: code)).to be_empty
  end

  it "gruppo senza argomenti → rifiutato con la spiegazione" do
    code = Accounts::TelegramLinkCode.issue(account: owner, organization: organization)

    expect(link(code, forum: false).error.code).to eq("R422-TELEGRAM-013")
    expect(Alerting::TelegramGroup.count).to eq(0)
  end

  it "chi non è più owner non collega niente" do
    member = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    code = Accounts::TelegramLinkCode.issue(account: member, organization: organization)

    expect(link(code).error.code).to eq("R403-TELEGRAM-012")
    expect(Alerting::TelegramGroup.count).to eq(0)
  end

  it "il codice della chat personale non collega un gruppo" do
    code = Accounts::TelegramLinkCode.issue(account: owner)

    expect(link(code).error.code).to eq("R404-TELEGRAM-001")
  end

  it "un gruppo diverso riparte senza argomenti, lo stesso gruppo li tiene" do
    Alerting::TelegramGroup.create!(organization: organization, account: owner, chat_id: "-100", topics: { "servers" => 3 })

    edit = stub_request(:post, %r{api.telegram.org/.*/editForumTopic})
           .with { |req| JSON.parse(req.body).values_at("message_thread_id", "icon_custom_emoji_id") == [ 3, "5350554349074391003" ] }
           .to_return(status: 200)

    link(Accounts::TelegramLinkCode.issue(account: owner, organization: organization))
    expect(Alerting::TelegramGroup.sole.topics).to eq("servers" => 3)
    expect(edit).to have_been_requested # CYRA-865: ricollegando, gli argomenti esistenti prendono l'icona

    link(Accounts::TelegramLinkCode.issue(account: owner, organization: organization), chat_id: -200)
    expect(Alerting::TelegramGroup.sole).to have_attributes(chat_id: "-200", topics: {})
  end
end
