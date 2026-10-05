# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DispatchSecretDeleted do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

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
                          role: role_with("Vault admin #{SecureRandom.hex(3)}", "secrets.manage"))
    account
  end

  def dispatch(variable_id: SecureRandom.uuid, name: "API_KEY", environment_label: "Production", actor: nil)
    described_class.call(project: project, variable_id: variable_id, name: name,
                         environment_label: environment_label, actor: actor)
  end

  describe "destinatari" do
    it "notifica l'owner dell'organizzazione sempre" do
      owner = create(:account)
      member!(owner, :owner)

      dispatch

      expect(Alerting::Notification.where(account: owner, event_type: :secret_deleted, subject: project)).to exist
    end

    it "notifica chi ha secrets.manage sul progetto" do
      manager = manager!

      dispatch

      expect(Alerting::Notification.where(account: manager, event_type: :secret_deleted, subject: project)).to exist
    end

    it "ESCLUDE chi vede il progetto ma non ha secrets.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)

      dispatch

      expect(Alerting::Notification.where(account: viewer)).not_to exist
    end

    it "ESCLUDE l'attore che ha cancellato, anche se è owner" do
      owner = create(:account)
      member!(owner, :owner)

      dispatch(actor: owner)

      expect(Alerting::Notification.where(account: owner)).not_to exist
    end

    it "un responsabile diverso dall'attore riceve comunque la notifica" do
      owner = create(:account)
      member!(owner, :owner)
      manager = manager!

      dispatch(actor: manager)

      expect(Alerting::Notification.where(account: owner, subject: project)).to exist
      expect(Alerting::Notification.where(account: manager)).not_to exist
    end

    it "senza attore (delete di sistema) notifica tutti i responsabili, nessuna esclusione" do
      owner = create(:account)
      member!(owner, :owner)

      dispatch(actor: nil)

      expect(Alerting::Notification.where(account: owner, subject: project)).to exist
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      manager = manager!
      dispatch
      expect(Alerting::Notification.where(account: manager, via: :in_app, event_type: :secret_deleted)).to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      manager = manager!
      expect { dispatch }.to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
      expect(Alerting::Notification.where(account: manager, via: :email, event_type: :secret_deleted)).to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization,
                                   email_cadences: { "secret_deleted" => "off" })
      dispatch
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

      dispatch

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: manager, via: :telegram, event_type: :secret_deleted)).to exist
    end

    it "telegram acceso ma account NON collegato → nessuna notifica telegram" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)

      dispatch

      expect(Alerting::Notification.where(account: manager, via: :telegram)).not_to exist
    end
  end

  describe "idempotenza (dedup_key ancorato all'id della riga distrutta, mai al nome)" do
    it "due dispatch con lo STESSO variable_id (retry dello stesso job) non duplicano" do
      manager = manager!
      variable_id = SecureRandom.uuid

      dispatch(variable_id: variable_id)
      expect { dispatch(variable_id: variable_id) }.not_to change(Alerting::Notification, :count)

      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(1)
    end

    it "un delete successivo (variable_id nuovo, anche stesso nome) genera una NUOVA notifica" do
      manager = manager!
      dispatch(variable_id: SecureRandom.uuid, name: "API_KEY")

      expect { dispatch(variable_id: SecureRandom.uuid, name: "API_KEY") }
        .to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(2)
    end
  end

  describe "contenuto" do
    it "il subject della notifica è il PROGETTO, mai la variabile (già distrutta)" do
      manager!
      result = dispatch
      expect(result).to be_ok

      notification = Alerting::Notification.find_by(event_type: :secret_deleted, via: :in_app)
      expect(notification.subject).to eq(project)
      expect(notification.subject).not_to be_a(Secrets::Variable)
    end

    it "titolo con nome/progetto/ambiente/attore, mai un valore" do
      manager!
      actor = create(:account, name: "Mario Rossi")
      dispatch(name: "DATABASE_URL", environment_label: "Staging", actor: actor)

      notification = Alerting::Notification.find_by(event_type: :secret_deleted, via: :in_app)
      expect(notification.title).to include("DATABASE_URL").and include(project.name)
                                                             .and include("Staging").and include("Mario Rossi")
      expect(notification.title).not_to include("s3cr3t")
      expect(notification.body).not_to include("s3cr3t")
    end
  end
end
