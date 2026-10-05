# frozen_string_literal: true

require "rails_helper"

# CYRA-852 — l'avviso va nell'argomento del suo tipo; l'argomento nasce al primo messaggio.
RSpec.describe Telegram::SendToGroup do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:group) { Alerting::TelegramGroup.create!(organization: organization, account: owner, chat_id: "-100") }
  let(:api) { "https://api.telegram.org/bot999:xyz" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
  end

  def topic_created(id)
    { status: 200, body: { ok: true, result: { message_thread_id: id } }.to_json }
  end

  it "crea l'argomento al primo avviso, con nome nella lingua dell'owner e icona, e lo riusa ai successivi" do
    critical_name = I18n.t("telegram.group.topics.critical", locale: owner.effective_locale)
    create_topic = stub_request(:post, "#{api}/createForumTopic")
                   .with { |req| JSON.parse(req.body).values_at("name", "icon_custom_emoji_id") == [ critical_name, "5312241539987020022" ] }.to_return(topic_created(7))
    send = stub_request(:post, "#{api}/sendMessage")
           .with { |req| JSON.parse(req.body).values_at("chat_id", "message_thread_id") == [ "-100", 7 ] }
           .to_return(status: 200)

    2.times { expect(described_class.call(group: group, event_type: "uptime_down", text: "giù")).to be_ok }

    expect(create_topic).to have_been_requested.once
    expect(send).to have_been_requested.twice
    expect(group.reload.topics).to eq("critical" => 7)
  end

  it "argomento non creabile → l'avviso va nel generale del gruppo" do
    stub_request(:post, "#{api}/createForumTopic").to_return(status: 400, body: { ok: false }.to_json)
    send = stub_request(:post, "#{api}/sendMessage")
           .with { |req| !JSON.parse(req.body).key?("message_thread_id") }.to_return(status: 200)

    expect(described_class.call(group: group, event_type: "server_cpu", text: "cpu")).to be_ok
    expect(send).to have_been_requested
    expect(group.reload.topics).to eq({})
  end

  it "argomento cancellato a mano → ne apre uno nuovo e riprova una volta" do
    group.update!(topics: { "servers" => 3 })
    stub_request(:post, "#{api}/createForumTopic").to_return(topic_created(9))
    stub_request(:post, "#{api}/sendMessage")
      .with { |req| JSON.parse(req.body)["message_thread_id"] == 3 }
      .to_return(status: 400, body: { ok: false, description: "Bad Request: message thread not found" }.to_json)
    retry_send = stub_request(:post, "#{api}/sendMessage")
                 .with { |req| JSON.parse(req.body)["message_thread_id"] == 9 }.to_return(status: 200)

    expect(described_class.call(group: group, event_type: "server_cpu", text: "cpu")).to be_ok
    expect(retry_send).to have_been_requested
    expect(group.reload.topics).to eq("servers" => 9)
  end

  # CYRA-874 — a 400 for any other reason (too long, bad HTML) must not open a duplicate topic.
  it "keeps the saved topic and creates no new one when Telegram rejects the message for another reason" do
    group.update!(topics: { "servers" => 3 })
    create_topic = stub_request(:post, "#{api}/createForumTopic").to_return(topic_created(9))
    stub_request(:post, "#{api}/sendMessage")
      .to_return(status: 400, body: { ok: false, description: "Bad Request: message is too long" }.to_json)

    expect(described_class.call(group: group, event_type: "server_cpu", text: "cpu")).to be_err
    expect(create_topic).not_to have_been_requested
    expect(group.reload.topics).to eq("servers" => 3)
  end

  it "Telegram irraggiungibile → errore, l'argomento salvato resta" do
    group.update!(topics: { "servers" => 3 })
    stub_request(:post, "#{api}/sendMessage").to_return(status: 502)

    expect(described_class.call(group: group, event_type: "server_cpu", text: "cpu")).to be_err
    expect(group.reload.topics).to eq("servers" => 3)
  end
end
