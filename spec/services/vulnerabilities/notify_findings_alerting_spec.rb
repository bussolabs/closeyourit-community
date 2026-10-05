# frozen_string_literal: true

require "rails_helper"

# Prova che l'avviso ARRIVA davvero a una persona, non solo che il job viene accodato: regole di
# default installate, job eseguiti per davvero, riga di notifica verificata. Stesso stampo di
# spec/services/uptime/record_check_alerting_spec.rb.
RSpec.describe "Vulnerabilities alerting", type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization) }
  let(:manifest) { create(:vulnerability_manifest, project: project) }
  let(:package) { create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0") }

  before do
    owner
    Alerting::Rules::InstallDefaults.call(organization: organization)
  end

  it "una vulnerabilità nuova diventa una notifica in-app per chi vede il progetto" do
    finding = create(:vulnerability_finding, project: project, package: package,
                                             advisory: create(:vulnerability_advisory, :high))

    perform_enqueued_jobs do
      Vulnerabilities::NotifyFindings.call(findings: [ finding ])
    end

    notification = Alerting::Notification.find_by(account: owner, via: :in_app,
                                                  event_type: :vulnerability_new)
    expect(notification).to be_present
    expect(notification.title).to include("rails@7.0.0")
    expect(notification.project).to eq(project)
  end

  it "il corpo dice cosa fare: la versione a cui aggiornare" do
    advisory = create(:vulnerability_advisory, :critical, aliases: [ "CVE-2026-9" ])
    finding = create(:vulnerability_finding, project: project, package: package, advisory: advisory,
                                             fixed_version: "7.0.8.1")

    perform_enqueued_jobs { Vulnerabilities::NotifyFindings.call(findings: [ finding ]) }

    notification = Alerting::Notification.find_by(event_type: :vulnerability_new)
    expect(notification.body).to include("7.0.8.1", "CVE-2026-9")
  end

  it "senza una versione che risolve, il corpo lo dice invece di tacere" do
    finding = create(:vulnerability_finding, :unfixable, project: project, package: package,
                                                         advisory: create(:vulnerability_advisory, :high))

    perform_enqueued_jobs { Vulnerabilities::NotifyFindings.call(findings: [ finding ]) }

    expect(Alerting::Notification.find_by(event_type: :vulnerability_new).body)
      .to include(I18n.t("alerting.content.vulnerability_new.body_unfixable",
                         advisory: finding.display_id))
  end

  it "le organizzazioni nuove nascono con la regola: nessuno resta scoperto per dimenticanza" do
    expect(organization.alerting_rules.where(event_type: :vulnerability_new)).to exist
    expect(organization.alerting_rules.where(event_type: :runtime_eol)).to exist
  end

  it "l'avviso non esce dall'organizzazione" do
    outsider = create(:account).tap do |account|
      create(:membership, account: account, organization: create(:organization), role: :owner)
    end
    finding = create(:vulnerability_finding, project: project, package: package,
                                             advisory: create(:vulnerability_advisory, :high))

    perform_enqueued_jobs { Vulnerabilities::NotifyFindings.call(findings: [ finding ]) }

    expect(Alerting::Notification.where(account: outsider)).not_to exist
  end
end
