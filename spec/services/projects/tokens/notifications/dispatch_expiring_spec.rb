# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Tokens::Notifications::DispatchExpiring do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:environment) { create(:environment, organization: organization).tap { |e| project.environments << e } }

  def member!(account, role = :member) = create(:membership, account: account, organization: organization, role: role)

  def role_with(name, *keys)
    role = create(:role, organization: organization, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  def manager!
    account = create(:account)
    member!(account)
    create(:project_membership, account: account, project: project)
    create(:account_role, account: account, organization: organization,
                          role: role_with("Token admin #{SecureRandom.hex(3)}", "tokens.manage"))
    account
  end

  def token_due_soon = create(:project_token, project: project, environment: environment, expires_at: 3.days.from_now)
  def token_expired = create(:project_token, :expired, project: project, environment: environment)
  def token_ok = create(:project_token, project: project, environment: environment, expires_at: 60.days.from_now)

  def dispatch(token, at: Time.current) = described_class.call(token: token, at: at)

  describe "destinatari" do
    it "notifica l'owner dell'organizzazione sempre" do
      owner = create(:account)
      member!(owner, :owner)
      token = token_due_soon

      dispatch(token)

      expect(Alerting::Notification.where(account: owner, event_type: :project_token_expiring, subject: token))
        .to exist
    end

    it "notifica chi ha tokens.manage sul progetto" do
      manager = manager!
      token = token_due_soon

      dispatch(token)

      expect(Alerting::Notification.where(account: manager, event_type: :project_token_expiring, subject: token))
        .to exist
    end

    it "ESCLUDE chi vede il progetto ma non ha tokens.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)

      dispatch(token_due_soon)

      expect(Alerting::Notification.where(account: viewer)).not_to exist
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      manager = manager!
      dispatch(token_due_soon)
      expect(Alerting::Notification.where(account: manager, via: :in_app, event_type: :project_token_expiring))
        .to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      manager = manager!
      expect { dispatch(token_due_soon) }.to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(Alerting::Notification.where(account: manager, via: :email, event_type: :project_token_expiring))
        .to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization,
                                   email_cadences: { "project_token_expiring" => "off" })
      dispatch(token_due_soon)
      expect(Alerting::Notification.where(account: manager, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: manager, via: :email)).not_to exist
    end

    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      manager = manager!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      manager.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)

      dispatch(token_due_soon)

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: manager, via: :telegram, event_type: :project_token_expiring))
        .to exist
    end

    it "telegram acceso ma account NON collegato → nessuna notifica telegram" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)

      dispatch(token_due_soon)

      expect(Alerting::Notification.where(account: manager, via: :telegram)).not_to exist
    end
  end

  describe "idempotenza" do
    it "due invocazioni per lo stesso (token, scadenza) creano una sola notifica per destinatario" do
      manager = manager!
      token = token_due_soon

      dispatch(token)
      expect { dispatch(token) }.not_to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(1)
    end

    it "spostare la scadenza riarma l'avviso (nuova finestra, nuova chiave di dedup)" do
      manager = manager!
      token = token_due_soon
      dispatch(token)

      token.update!(expires_at: 5.days.from_now)

      expect { dispatch(token) }.to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(2)
    end
  end

  describe "guardia difensiva" do
    it "token con scadenza lontana (:ok) → no-op" do
      manager!
      expect { dispatch(token_ok) }.not_to change(Alerting::Notification, :count)
    end

    it "token senza scadenza (:none) → no-op" do
      manager!
      token = create(:project_token, project: project, environment: environment)
      expect { dispatch(token) }.not_to change(Alerting::Notification, :count)
    end

    it "token revocato → no-op anche se in scadenza" do
      manager!
      token = create(:project_token, project: project, environment: environment,
                                     expires_at: 3.days.from_now, revoked_at: Time.current)
      expect { dispatch(token) }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "contenuto" do
    it "il titolo porta nome del token, progetto e ambiente; mai il prefisso del segreto" do
      manager = manager!
      token = token_due_soon

      dispatch(token)

      notification = Alerting::Notification.find_by(account: manager, subject: token, via: :in_app)
      expect(notification.title).to include(token.name, project.name, environment.label)
      expect("#{notification.title}#{notification.body}").not_to include(token.token_prefix)
    end

    it "distingue il token già scaduto da quello in preavviso" do
      manager = manager!
      dispatch(token_expired)

      notification = Alerting::Notification.find_by(account: manager, via: :in_app)
      expect(notification.body).to eq(I18n.t("member.tokens.expiry.expired_days", count: 1))
    end
  end
end
