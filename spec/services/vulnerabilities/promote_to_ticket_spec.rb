# frozen_string_literal: true

require "rails_helper"

# Trasformare una vulnerabilità in un ticket è il punto in cui un dato di monitoraggio diventa lavoro
# da fare. Il titolo è la sola parte che un non tecnico legge in lista, l'analisi porta tutto il resto,
# e la promozione deve restare idempotente: la stessa vulnerabilità può essere promossa da una persona
# e dalla scansione notturna nello stesso momento.
RSpec.describe Vulnerabilities::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end
  let(:manifest) { create(:vulnerability_manifest, :npm, project:, path: "web/package-lock.json") }
  let(:package) do
    create(:vulnerability_package, manifest:, name: "lodash", version: "4.17.20", direct: true)
  end
  let(:advisory) do
    create(:vulnerability_advisory, :high, osv_id: "GHSA-abc", aliases: [ "CVE-2026-1" ],
                                           summary: "Prototype pollution in lodash",
                                           cwe_ids: [ "CWE-1321" ])
  end
  let(:finding) do
    create(:vulnerability_finding, project:, package:, advisory:, fixed_version: "4.17.21")
  end

  before { Types::InstallDefaults.call(organization:) }

  def promote(group: finding) = described_class.call(group:, reporter: owner)

  it "il titolo dice gravità, cosa e quale riferimento" do
    ticket = promote.value

    expect(ticket.title).to eq(
      I18n.t("member.monitoring.vulnerabilities.ticket_title",
             severity: I18n.t("member.monitoring.vulnerabilities.severity.high"),
             package: "lodash@4.17.20", advisory: "CVE-2026-1")
    )
  end

  it "lo scenario dice dove sta il pacchetto e cosa ci si aspetta" do
    scenario = promote.value.scenarios.sole

    expect(scenario.step_given).to eq("Reported from dependency scanning.")
    expect(scenario.step_when).to eq("lodash@4.17.20 is resolved in web/package-lock.json")
    expect(scenario.step_then).to eq("Prototype pollution in lodash")
    expect(scenario.step_expected).to eq("The dependency is updated to 4.17.21.")
  end

  it "senza una versione che risolve, l'obiettivo è togliere o sostituire, non aggiornare" do
    finding.update!(fixed_version: nil)

    expect(promote.value.scenarios.sole.step_expected)
      .to eq("The dependency is replaced or removed: no fixed version exists yet.")
  end

  it "un advisory senza riassunto non lascia lo scenario muto" do
    advisory.update!(summary: nil)

    expect(promote.value.scenarios.sole.step_then)
      .to eq("A known vulnerability affects this version.")
  end

  it "l'analisi tecnica porta tutto quello che serve per decidere" do
    analysis = promote.value.technical_analysis

    expect(analysis).to include("Advisory: GHSA-abc", "Aliases: CVE-2026-1", "Severity: high",
                                "CWE: CWE-1321", "Package: lodash@4.17.20 (npm)",
                                "Manifest: web/package-lock.json", "Direct dependency: yes",
                                "Fixed in: 4.17.21", "Reference: https://osv.dev/vulnerability/GHSA-abc")
  end

  it "le righe che non abbiamo restano fuori invece di comparire vuote" do
    advisory.update!(aliases: [], cvss: nil, cwe_ids: [])
    finding.update!(fixed_version: nil)
    package.update!(direct: false)

    analysis = promote.value.technical_analysis

    expect(analysis).to include("Direct dependency: no")
    expect(analysis).not_to include("Aliases:", "CVSS:", "CWE:", "Fixed in:")
  end

  it "il ticket nasce nel progetto della vulnerabilità, aperto e ad alta priorità" do
    ticket = promote.value

    expect(ticket.project).to eq(project)
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("high")
    expect(finding.reload.ticket).to eq(ticket)
    expect(finding).to be_promoted
  end

  it "promuovere due volte non apre un secondo ticket" do
    promote

    expect do
      result = promote
      expect(result).to be_err
      expect(result.error.code).to eq("R422-VULN-001")
    end.not_to change(Ticketing::Ticket, :count)
  end

  # Il testo dell'advisory arriva da un database esterno e non ha tetto: una descrizione fluviale non
  # deve far fallire la creazione del ticket, perché chi promuove non può correggere quel dato.
  it "un riferimento lunghissimo viene troncato invece di far fallire la promozione" do
    advisory.update!(osv_id: "GHSA-#{'x' * 5_000}")

    result = promote

    expect(result).to be_ok
    expect(result.value.technical_analysis.length)
      .to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
  end

  it "un nome di pacchetto abnorme non sfonda il campo del titolo" do
    package.update!(name: "a" * 500)

    expect(promote.value.title.length).to be <= 255
  end

  it "chi non vede il progetto non promuove niente" do
    estraneo = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }

    result = described_class.call(group: finding, reporter: estraneo)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-TICKET-001")
    expect(finding.reload).not_to be_promoted
  end
end
