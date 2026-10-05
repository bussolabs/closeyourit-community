# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::ScanProject do
  let(:repository) { create(:github_repository) }
  let(:project) { repository.project }
  let(:github_client) { instance_double(Github::Client) }
  let(:osv_client) { instance_double(Vulnerabilities::Osv::Client) }
  let(:lockfile) { Rails.root.join("spec/fixtures/vulnerabilities/gemfile_lock.txt").read }

  def tree_with(*paths)
    { entries: paths.map { |path| { "path" => path, "type" => "blob", "sha" => "sha-#{path}" } },
      truncated: false }
  end

  def scan = described_class.call(project: project, github_client: github_client, osv_client: osv_client)

  before do
    allow(github_client).to receive(:git_tree).and_return(tree_with("Gemfile.lock"))
    allow(github_client).to receive(:blob).and_return(lockfile)
  end

  it "va dal repository alla riga di vulnerabilità in un passaggio solo" do
    allow(osv_client).to receive(:query_batch) do |queries|
      queries.map { |query| query[:name] == "actionpack" ? [ "GHSA-1" ] : [] }
    end
    allow(osv_client).to receive(:vulnerability).with("GHSA-1").and_return(
      "id" => "GHSA-1", "database_specific" => { "severity" => "CRITICAL" },
      "affected" => [ { "package" => { "name" => "actionpack", "ecosystem" => "RubyGems" },
                        "ranges" => [ { "events" => [ { "fixed" => "7.0.8.1" } ] } ] } ]
    )

    result = scan

    expect(result).to be_ok
    finding = Vulnerabilities::Finding.sole
    expect(finding.package_name).to eq("actionpack")
    expect(finding.fixed_version).to eq("7.0.8.1")
    expect(finding.advisory).to be_severity_critical
  end

  it "interroga OSV una volta per coordinata, non una per gemma ripetuta" do
    allow(osv_client).to receive(:query_batch) { |queries| queries.map { [] } }

    scan

    expect(osv_client).to have_received(:query_batch).once
  end

  it "nessuna vulnerabilità: nessuna riga, e la scansione resta ok" do
    allow(osv_client).to receive(:query_batch) { |queries| queries.map { [] } }

    expect(scan).to be_ok
    expect(Vulnerabilities::Finding.count).to eq(0)
  end

  it "un manifest illeggibile non ferma gli altri" do
    allow(github_client).to receive(:git_tree)
      .and_return(tree_with("Gemfile.lock", "web/package-lock.json"))
    allow(github_client).to receive(:blob).with(anything, anything, "sha-Gemfile.lock").and_return(lockfile)
    allow(github_client).to receive(:blob).with(anything, anything, "sha-web/package-lock.json")
                                          .and_return("{ rotto")
    allow(osv_client).to receive(:query_batch) { |queries| queries.map { [] } }

    expect(scan).to be_ok
    expect(project.vulnerability_manifests.failing.pluck(:path)).to eq([ "web/package-lock.json" ])
    expect(project.vulnerability_manifests.parsed.sole.packages).to be_present
  end

  it "OSV irraggiungibile: errore dichiarato, e ciò che sapevamo resta" do
    existing = create(:vulnerability_finding, project: project)
    allow(osv_client).to receive(:query_batch)
      .and_raise(Vulnerabilities::Osv::Client::Error.new("giù", code: "R502-OSV-001"))

    result = scan

    expect(result).to be_err
    expect(result.error.code).to eq("R502-OSV-001")
    expect(existing.reload).to be_status_open
  end

  it "un progetto senza repository non è scansionabile" do
    result = described_class.call(project: create(:project), github_client: github_client,
                                  osv_client: osv_client)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-VULN-002")
  end

  it "repository senza lockfile: chiude ciò che era aperto, perché non è più dimostrabile" do
    stale = create(:vulnerability_finding, project: project)
    allow(github_client).to receive(:git_tree).and_return(tree_with("README.md"))

    expect(scan).to be_ok
    expect(stale.reload).to be_status_resolved
  end

  # Il caso di CYRA-811: fra due scansioni cambia una dipendenza che nessun advisory colpisce. La
  # riga già decisa deve restare quella di prima, non ricomparire azzerata.
  it "una vulnerabilità già decisa non ricompare come nuova quando cambia un'altra dipendenza" do
    allow(osv_client).to receive(:query_batch) do |queries|
      queries.map { |query| query[:name] == "actionpack" ? [ "GHSA-1" ] : [] }
    end
    allow(osv_client).to receive(:vulnerability).with("GHSA-1").and_return(
      "id" => "GHSA-1", "database_specific" => { "severity" => "HIGH" },
      "affected" => [ { "package" => { "name" => "actionpack", "ecosystem" => "RubyGems" },
                        "ranges" => [ { "events" => [ { "fixed" => "7.0.8.1" } ] } ] } ]
    )
    scan
    finding = Vulnerabilities::Finding.sole
    finding.update!(status: :ignored, triage_note: "Non raggiungibile dal nostro codice.")
    first_seen_at = finding.first_seen_at
    allow(github_client).to receive(:blob)
      .and_return(lockfile.sub("concurrent-ruby (1.2.2)", "concurrent-ruby (1.3.0)"))

    scan

    expect(Vulnerabilities::Finding.sole.id).to eq(finding.id)
    expect(finding.reload).to be_status_ignored
    expect(finding.first_seen_at).to eq(first_seen_at)
  end

  # CYRA-810 — un file delle dipendenze che non si riesce a leggere non dimostra che le sue
  # vulnerabilità siano sparite: sono solo diventate invisibili. Restano note, il file resta segnato
  # come non verificato, e gli altri file del progetto si analizzano lo stesso.
  describe "un file delle dipendenze che la scansione non riesce a leggere" do
    let(:npm_lock) { Rails.root.join("spec/fixtures/vulnerabilities/package-lock.json").read }

    # Il progetto ha due file: un Gemfile.lock sempre leggibile e un package-lock.json che di volta
    # in volta risponde bene, male, o non risponde affatto.
    def scan_reading(npm)
      allow(github_client).to receive(:git_tree)
        .and_return(tree_with("Gemfile.lock", "web/package-lock.json"))
      allow(github_client).to receive(:blob).with(anything, anything, "sha-Gemfile.lock")
                                            .and_return(lockfile)
      stub = allow(github_client).to receive(:blob).with(anything, anything, "sha-web/package-lock.json")
      npm.is_a?(Exception) ? stub.and_raise(npm) : stub.and_return(npm)
      scan
    end

    before do
      allow(osv_client).to receive(:query_batch) do |queries|
        queries.map { |query| query[:name] == "lodash" && query[:version] == "4.17.15" ? [ "GHSA-LODASH" ] : [] }
      end
      allow(osv_client).to receive(:vulnerability).with("GHSA-LODASH").and_return(
        "id" => "GHSA-LODASH", "database_specific" => { "severity" => "HIGH" },
        "affected" => [ { "package" => { "name" => "lodash", "ecosystem" => "npm" },
                          "ranges" => [ { "events" => [ { "introduced" => "0" },
                                                        { "fixed" => "4.17.21" } ] } ] } ]
      )
    end

    # I quattro modi in cui un lockfile può restare non verificato: il parser non lo capisce, il
    # contenuto non c'è più, è oltre il tetto di dimensione, GitHub non risponde.
    {
      "il parser non lo capisce" => -> { "{ rotto" },
      "il contenuto non c'è più" => -> { nil },
      "supera la dimensione massima" => lambda {
        stub_const("Vulnerabilities::Constants::MAX_MANIFEST_BYTES", lockfile.bytesize + 1)
        "x" * (lockfile.bytesize + 2)
      },
      "GitHub non risponde" => -> { Github::Client::Error.new("giù", code: "R502-GITHUB-001") }
    }.each do |reason, unreadable|
      it "#{reason}: le sue vulnerabilità restano note" do
        scan_reading(npm_lock)
        finding = Vulnerabilities::Finding.sole

        expect(scan_reading(instance_exec(&unreadable))).to be_ok

        expect(finding.reload).to be_status_open
        expect(finding.resolved_at).to be_nil
      end
    end

    it "il file letto correttamente viene analizzato lo stesso" do
      scan_reading("{ rotto")

      parsed = project.vulnerability_manifests.parsed
      expect(parsed.pluck(:path)).to eq([ "Gemfile.lock" ])
      expect(parsed.sole.packages.pluck(:name)).to include("rails", "actionpack")
    end

    it "il file non letto resta segnato come non verificato" do
      scan_reading("{ rotto")

      expect(project.vulnerability_manifests.failing.pluck(:path)).to eq([ "web/package-lock.json" ])
    end

    it "nemmeno un file leggibile: non si chiude niente" do
      scan_reading(npm_lock)
      finding = Vulnerabilities::Finding.sole
      allow(github_client).to receive(:blob).and_return("{ rotto")

      expect(scan).to be_ok
      expect(finding.reload).to be_status_open
    end

    # Il contrario della protezione: appena il file torna leggibile e il pacchetto è davvero
    # aggiornato, la riga se ne va. Altrimenti un errore di lettura la renderebbe eterna.
    it "il file torna leggibile con il pacchetto aggiornato: la riga se ne va" do
      scan_reading(npm_lock)
      finding = Vulnerabilities::Finding.sole
      scan_reading("{ rotto")

      scan_reading(npm_lock.gsub("4.17.15", "4.17.21"))

      expect(Vulnerabilities::Finding.exists?(finding.id)).to be(false)
      expect(project.vulnerability_manifests.failing).to be_empty
    end
  end
end
