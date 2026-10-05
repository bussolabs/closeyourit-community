# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DispatchRotationDue do
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
                          role: role_with("Vault admin #{SecureRandom.hex(3)}", "secrets.manage"))
    account
  end

  def variable_overdue(days_ago_rotated: 2)
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 1, rotated_at: Time.current - days_ago_rotated.days)
  end

  def variable_due_soon
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 14, rotated_at: Time.current)
  end

  def variable_ok
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 90, rotated_at: Time.current)
  end

  def dispatch(variable, at: Time.current)
    described_class.call(variable: variable, at: at)
  end

  describe "destinatari" do
    it "notifica l'owner dell'organizzazione sempre" do
      owner = create(:account)
      member!(owner, :owner)
      variable = variable_overdue

      dispatch(variable)

      expect(Alerting::Notification.where(account: owner, event_type: :secret_rotation_due, subject: variable)).to exist
    end

    it "notifica chi ha secrets.manage sul progetto" do
      manager = manager!
      variable = variable_overdue

      dispatch(variable)

      expect(Alerting::Notification.where(account: manager, event_type: :secret_rotation_due, subject: variable)).to exist
    end

    it "ESCLUDE chi vede il progetto ma non ha secrets.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)

      dispatch(variable_overdue)

      expect(Alerting::Notification.where(account: viewer)).not_to exist
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      manager = manager!
      dispatch(variable_overdue)
      expect(Alerting::Notification.where(account: manager, via: :in_app, event_type: :secret_rotation_due)).to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      manager = manager!
      expect { dispatch(variable_overdue) }.to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
      expect(Alerting::Notification.where(account: manager, via: :email, event_type: :secret_rotation_due)).to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization,
                                   email_cadences: { "secret_rotation_due" => "off" })
      dispatch(variable_overdue)
      expect(Alerting::Notification.where(account: manager, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: manager, via: :email)).not_to exist
    end

    it "email_enabled = false → solo in-app" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization, email_enabled: false)
      dispatch(variable_overdue)
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

      dispatch(variable_overdue)

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: manager, via: :telegram, event_type: :secret_rotation_due)).to exist
    end

    it "telegram acceso ma account NON collegato → nessuna notifica telegram" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)

      dispatch(variable_overdue)

      expect(Alerting::Notification.where(account: manager, via: :telegram)).not_to exist
    end

    it "telegram: re-dispatch dello stesso (variabile, scadenza) non duplica la notifica telegram" do
      manager = manager!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      manager.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)
      variable = variable_overdue

      dispatch(variable)
      expect { dispatch(variable) }
        .not_to change { Alerting::Notification.where(account: manager, via: :telegram).count }
    end
  end

  describe "idempotenza" do
    it "due invocazioni per lo stesso (variabile, scadenza) creano una sola notifica per destinatario" do
      manager = manager!
      variable = variable_overdue

      dispatch(variable)
      expect { dispatch(variable) }.not_to change(Alerting::Notification, :count)

      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(1)
    end

    it "la rotazione del secret sposta rotate_by → nuova finestra, nuovo avviso" do
      manager = manager!
      variable = variable_overdue
      dispatch(variable)

      # Rotazione reale (il valore è cambiato): rotated_at avanza e la policy resta attiva → rotate_by
      # si sposta, la dedup_key cambia, e la variabile è ancora :due_soon con la nuova finestra.
      variable.update!(rotated_at: Time.current, rotation_interval_days: 3)

      expect { dispatch(variable) }.to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(2)
    end
  end

  describe "guardia difensiva (fuori scope A1)" do
    it "variabile :ok (non ancora in preavviso) → no-op" do
      manager!
      expect { dispatch(variable_ok) }.not_to change(Alerting::Notification, :count)
    end

    it "variabile :none (nessuna policy di rotazione) → no-op" do
      manager!
      variable = create(:secret_variable, project: project, environment: environment)
      expect { dispatch(variable) }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "contenuto" do
    it "il valore del secret non compare mai nel titolo/corpo della notifica" do
      manager = manager!
      variable = variable_overdue

      dispatch(variable)

      notification = Alerting::Notification.find_by(account: manager, subject: variable, via: :in_app)
      expect(notification.title).not_to include(variable.value)
      expect(notification.body).not_to include(variable.value)
    end
  end
end
