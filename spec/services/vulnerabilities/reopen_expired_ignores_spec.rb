# frozen_string_literal: true

require "rails_helper"

# CYRA-1144 — il controllo giornaliero: le ignorate arrivate alla scadenza tornano aperte, e l'avviso
# arriva davvero a una persona con motivo, autore e data (stesso stampo di
# spec/services/vulnerabilities/notify_findings_alerting_spec.rb).
RSpec.describe Vulnerabilities::ReopenExpiredIgnores, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:author) { create(:account, name: "Ada Lovelace") }
  let(:project) { create(:project, organization: organization) }

  def ignored_finding(ignored_until:, path: "Gemfile-#{SecureRandom.hex(4)}.lock")
    manifest = create(:vulnerability_manifest, project: project, path: path)
    package = create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0")
    create(:vulnerability_finding, project: project, package: package, status: :ignored,
                                   triage_note: "Solo sviluppo", ignored_until: ignored_until, ignored_by: author)
  end

  before do
    owner
    Alerting::Rules::InstallDefaults.call(organization: organization)
  end

  it "riapre le ignorate scadute e lascia stare le altre" do
    expired = ignored_finding(ignored_until: Date.yesterday)
    due_today = ignored_finding(ignored_until: Date.current)
    future = ignored_finding(ignored_until: Date.tomorrow)
    legacy = ignored_finding(ignored_until: nil)

    result = described_class.call

    expect(result.value).to eq(2)
    expect(expired.reload).to be_status_open
    expect(due_today.reload).to be_status_open
    expect(future.reload).to be_status_ignored
    expect(legacy.reload).to be_status_ignored
  end

  it "accoda un avviso per ogni riga riaperta" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    ignored_finding(ignored_until: Date.tomorrow)

    expect { described_class.call }
      .to have_enqueued_job(Alerting::EvaluateJob).once
      .with(hash_including(event_type: "vulnerability_ignore_expired", subject_id: finding.id,
                           project_id: project.id,
                           decision: { "reason" => "Solo sviluppo", "author" => "Ada Lovelace",
                                       "until" => Date.yesterday.iso8601 }))
  end

  it "l'avviso arriva a chi vede il progetto, con motivo, autore e data, e porta alla scheda" do
    finding = ignored_finding(ignored_until: Date.yesterday)

    perform_enqueued_jobs { described_class.call }

    notification = Alerting::Notification.find_by(account: owner, via: :in_app,
                                                  event_type: :vulnerability_ignore_expired)
    expect(notification).to be_present
    expect(notification.title).to include("rails@7.0.0")
    expect(notification.body).to include("Solo sviluppo", "Ada Lovelace", I18n.l(Date.yesterday, format: :long))
    expect(notification.url).to eq("/member/monitoring/vulnerabilities/#{finding.id}")
  end

  it "la riapertura automatica conserva la decisione scaduta: è il contenuto dell'avviso" do
    finding = ignored_finding(ignored_until: Date.yesterday)

    described_class.call

    expect(finding.reload).to have_attributes(status: "open", triage_note: "Solo sviluppo",
                                              ignored_until: Date.yesterday, ignored_by_id: author.id)
  end

  it "un secondo giro non riapre né avvisa di nuovo" do
    ignored_finding(ignored_until: Date.yesterday)
    described_class.call

    expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "se l'avviso non si può accodare la riga resta ignorata, e il giro successivo ci riprova" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)

    expect { described_class.call }.to raise_error(ActiveJob::EnqueueError)
    expect(finding.reload).to be_status_ignored

    allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original
    expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob).once
    expect(finding.reload).to be_status_open
  end

  # ActiveJob intercetta l'EnqueueError dell'adattatore e restituisce false invece di sollevarlo.
  it "se la coda rifiuta l'avviso restituendo false la riga resta ignorata" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_return(false)

    expect { described_class.call }.to raise_error(ActiveJob::EnqueueError)
    expect(finding.reload).to be_status_ignored
  end

  it "l'avviso racconta la decisione scaduta anche se la riga cambia prima che parta" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    expired_on = I18n.l(Date.yesterday, format: :long)
    described_class.call

    other = create(:account, name: "Grace Hopper")
    finding.reload.update!(status: :ignored, triage_note: "Rivalutata", ignored_until: Date.current + 30,
                           ignored_by: other)
    perform_enqueued_jobs

    notification = Alerting::Notification.find_by(account: owner, via: :in_app,
                                                  event_type: :vulnerability_ignore_expired)
    expect(notification.body).to include("Solo sviluppo", "Ada Lovelace", expired_on)
    expect(notification.body).not_to include("Rivalutata", "Grace Hopper")
  end

  it "l'avviso conserva autore e data anche dopo una riapertura a mano" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    described_class.call

    finding.reload.reopen!
    perform_enqueued_jobs

    notification = Alerting::Notification.find_by(account: owner, via: :in_app,
                                                  event_type: :vulnerability_ignore_expired)
    expect(notification.body).to include("Solo sviluppo", "Ada Lovelace", I18n.l(Date.yesterday, format: :long))
  end

  it "una riga riaperta a mano prima del giro non viene toccata né annunciata" do
    finding = ignored_finding(ignored_until: Date.yesterday)
    finding.reopen!

    expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(finding.reload).to have_attributes(status: "open", ignored_until: nil)
  end

  it "il job giornaliero passa dal servizio" do
    finding = ignored_finding(ignored_until: Date.yesterday)

    Vulnerabilities::ReopenExpiredIgnoresJob.perform_now

    expect(finding.reload).to be_status_open
  end
end
