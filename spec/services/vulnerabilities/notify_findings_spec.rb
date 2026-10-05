# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::NotifyFindings do
  let(:organization) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization) }
  let(:manifest) { create(:vulnerability_manifest, project: project) }
  let(:package) { create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0") }

  def finding_with(severity)
    create(:vulnerability_finding, project: project, package: package,
                                   advisory: create(:vulnerability_advisory, severity: severity))
  end

  before do
    owner
    create(:ticket_status, organization: organization, code: "open", position: 0)
    create(:ticket_priority, organization: organization, code: "high", position: 0)
  end

  it "accoda un avviso per ogni vulnerabilità nuova" do
    finding = finding_with(:moderate)

    expect { described_class.call(findings: [ finding ]) }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "vulnerability_new", subject_id: finding.id,
                           project_id: project.id))
  end

  describe "ticket automatico" do
    it "scatta su critica" do
      finding = finding_with(:critical)

      expect { described_class.call(findings: [ finding ]) }.to change(Ticketing::Ticket, :count).by(1)
      expect(finding.reload).to be_promoted
    end

    it "scatta su alta" do
      finding = finding_with(:high)

      expect { described_class.call(findings: [ finding ]) }.to change(Ticketing::Ticket, :count).by(1)
    end

    it "NON scatta su media o bassa" do
      findings = [ finding_with(:moderate), finding_with(:low) ]

      expect { described_class.call(findings: findings) }.not_to change(Ticketing::Ticket, :count)
    end

    it "NON scatta su gravità sconosciuta: non classificata non vuol dire grave" do
      finding = finding_with(:unknown)

      expect { described_class.call(findings: [ finding ]) }.not_to change(Ticketing::Ticket, :count)
      expect(finding.reload).not_to be_promoted
    end

    it "rispetta l'interruttore del progetto" do
      project.update!(vulnerability_auto_ticket: false)
      finding = finding_with(:critical)

      expect { described_class.call(findings: [ finding ]) }.not_to change(Ticketing::Ticket, :count)
    end

    it "non crea due ticket per la stessa vulnerabilità" do
      finding = finding_with(:critical)
      described_class.call(findings: [ finding ])

      expect { described_class.call(findings: [ finding.reload ]) }
        .not_to change(Ticketing::Ticket, :count)
    end

    it "il ticket porta gravità, libreria e riferimento nel titolo" do
      advisory = create(:vulnerability_advisory, :critical, aliases: [ "CVE-2026-1" ])
      finding = create(:vulnerability_finding, project: project, package: package, advisory: advisory)

      described_class.call(findings: [ finding ])

      expect(finding.reload.ticket.title).to include("Critica", "rails@7.0.0", "CVE-2026-1")
    end

    it "l'analisi tecnica porta advisory, pacchetto e riferimento" do
      finding = finding_with(:critical)

      described_class.call(findings: [ finding ])

      analysis = finding.reload.ticket.technical_analysis
      expect(analysis).to include("Advisory:", "Package: rails@7.0.0", "Manifest: #{manifest.path}")
      expect(analysis.length).to be <= Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS
    end

    it "senza proprietario dell'organizzazione l'avviso resta, il ticket no" do
      orphan_project = create(:project)
      finding = create(:vulnerability_finding, project: orphan_project,
                                               package: create(:vulnerability_package,
                                                               manifest: create(:vulnerability_manifest,
                                                                                project: orphan_project)),
                                               advisory: create(:vulnerability_advisory, :critical))
      orphan_project.organization.memberships.where(role: :owner).destroy_all

      expect { described_class.call(findings: [ finding ]) }
        .to have_enqueued_job(Alerting::EvaluateJob)
      expect(finding.reload).not_to be_promoted
    end
  end

  it "una lista vuota non fa niente" do
    expect { described_class.call(findings: []) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
