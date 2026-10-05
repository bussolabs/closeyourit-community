# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Notifications::Dispatch do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:author) { member_seeing(shared) }
  let(:recipient) { member_seeing(shared) }
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: author, account_b: recipient).value
  end

  # Messaggio creato diretto (niente PostMessage#after_post): isola Dispatch dall'enqueue automatico
  # del job → il test è indipendente dall'adapter (:inline vs :test).
  def build_message(body)
    conversation.messages.create!(body: body, author: author, organization_id: org.id)
  end

  def in_app_for(account)
    Alerting::Notification.where(account_id: account.id, via: :in_app)
  end

  it "notifica l'audience escludendo l'autore" do
    message = build_message("ciao")
    described_class.call(message: message)

    expect(in_app_for(recipient).count).to eq(1)
    expect(in_app_for(author).count).to eq(0)
  end

  it "usa chat_message per un messaggio semplice" do
    message = build_message("ciao")
    described_class.call(message: message)
    expect(in_app_for(recipient).first.event_type).to eq("chat_message")
  end

  it "usa chat_mentioned per chi è menzionato via @handle" do
    message = build_message("ehi @#{recipient.handle} guarda")
    described_class.call(message: message)
    expect(in_app_for(recipient).first.event_type).to eq("chat_mentioned")
  end

  it "salta chi ha silenziato la conversazione" do
    conversation.participants.find_by(account_id: recipient.id).update!(muted_at: Time.current)
    message = build_message("ciao")
    described_class.call(message: message)
    expect(in_app_for(recipient).count).to eq(0)
  end

  it "cadenza email off per l'evento → nessuna email, ma l'in-app resta" do
    Alerting::Preference.create!(account: recipient, organization: org,
                                 email_cadences: { "chat_message" => "off" })
    message = build_message("ciao")
    described_class.call(message: message)
    expect(in_app_for(recipient).count).to eq(1)
    expect(Alerting::Notification.where(account_id: recipient.id, via: :email).count).to eq(0)
  end

  it "è idempotente: due dispatch → una sola notifica per canale" do
    message = build_message("ciao")
    described_class.call(message: message)
    described_class.call(message: message)
    expect(in_app_for(recipient).count).to eq(1)
  end

  it "crea anche la notifica email (preferenze default)" do
    message = build_message("ciao")
    described_class.call(message: message)
    expect(Alerting::Notification.where(account_id: recipient.id, via: :email).count).to eq(1)
  end

  it "in quiet hours l'email è creata ma trattenuta (:held)" do
    Alerting::Preference.create!(account: recipient, organization: org,
                                 quiet_hours_start: 0, quiet_hours_end: 23, quiet_hours_tz: "UTC")
    message = build_message("ciao")
    travel_to(Time.utc(2026, 1, 1, 12, 0)) { described_class.call(message: message) }
    email = Alerting::Notification.where(account_id: recipient.id, via: :email).first
    expect(email.status).to eq("held")
  end

  it "in-app sempre attiva anche col vecchio flag in_app_enabled = false; l'email resta" do
    Alerting::Preference.create!(account: recipient, organization: org,
                                 in_app_enabled: false, email_enabled: true)
    message = build_message("ciao")
    described_class.call(message: message)
    expect(in_app_for(recipient).count).to eq(1)
    expect(Alerting::Notification.where(account_id: recipient.id, via: :email).count).to eq(1)
  end

  it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
    stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
    recipient.update!(telegram_chat_id: "900")
    Alerting::Preference.create!(account: recipient, organization: org, telegram_enabled: true)
    message = build_message("ciao")

    described_class.call(message: message)

    expect(stub).to have_been_requested
    expect(Alerting::Notification.where(account_id: recipient.id, via: :telegram).count).to eq(1)
  end

  it "no-op se il messaggio è nil (retry innocuo)" do
    result = described_class.call(message: nil)
    expect(result).to be_ok
    expect(result.value).to eq(0)
  end

  it "salta un ex-membro dell'organizzazione (revoca live, niente notifiche né email)" do
    message = build_message("ciao")
    Connections::Membership.where(account_id: recipient.id, organization_id: org.id).destroy_all
    described_class.call(message: message)
    expect(Alerting::Notification.where(account_id: recipient.id).count).to eq(0)
  end

  it "chi silenzia NON riceve nemmeno se menzionato (mute batte mention)" do
    conversation.participants.find_by(account_id: recipient.id).update!(muted_at: Time.current)
    message = build_message("ehi @#{recipient.handle} guarda")
    described_class.call(message: message)
    expect(in_app_for(recipient).count).to eq(0)
  end

  it "applica la cadenza email PER destinatario, non quella del primo (in-app a tutti)" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    channel = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: owner).value
    no_email = member_seeing(shared)
    with_email = member_seeing(shared)
    Alerting::Preference.create!(account: no_email, organization: org, email_cadences: { "chat_message" => "off" })
    message = channel.messages.create!(body: "misto", author: owner, organization_id: org.id)

    described_class.call(message: message)

    expect(in_app_for(no_email).count).to eq(1)
    expect(in_app_for(with_email).count).to eq(1)
    expect(Alerting::Notification.where(account_id: no_email.id, via: :email).count).to eq(0)
    expect(Alerting::Notification.where(account_id: with_email.id, via: :email).count).to eq(1)
  end

  it "notifica l'audience di un canale di progetto (titolo dal contesto)" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    channel = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: owner).value
    seer = member_seeing(shared)
    message = channel.messages.create!(body: "nel canale", author: owner, organization_id: org.id)

    described_class.call(message: message)
    expect(in_app_for(seer).count).to eq(1)
  end
end
