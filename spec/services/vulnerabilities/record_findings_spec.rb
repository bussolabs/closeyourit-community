# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::RecordFindings do
  let(:manifest) { create(:vulnerability_manifest) }
  let(:project) { manifest.project }
  let(:package) { create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0") }
  let(:advisory) do
    create(:vulnerability_advisory, :high, osv_id: "GHSA-1", affected: [
             { "package" => { "name" => "rails", "ecosystem" => "RubyGems" },
               "ranges" => [ { "events" => [ { "introduced" => "0" }, { "fixed" => "7.0.8.1" } ] } ] }
           ])
  end
  let(:matches) { { package.osv_key => [ advisory ] } }

  def record(matches_arg = matches, packages: [ package ], now: Time.current, unverified_manifest_ids: [])
    described_class.call(project: project, matches: matches_arg, packages: packages, now: now,
                         unverified_manifest_ids: unverified_manifest_ids)
  end

  it "apre una riga per ogni coppia pacchetto+advisory" do
    result = record

    expect(result).to be_ok
    finding = Vulnerabilities::Finding.sole
    expect(finding.package).to eq(package)
    expect(finding.advisory).to eq(advisory)
    expect(finding).to be_status_open
  end

  it "riporta le nuove aperture: sono l'unico insieme su cui avvisare qualcuno" do
    result = record

    expect(result.value.opened.map(&:id)).to eq(Vulnerabilities::Finding.pluck(:id))
  end

  it "compila la versione che risolve leggendola dall'advisory" do
    record
    expect(Vulnerabilities::Finding.sole.fixed_version).to eq("7.0.8.1")
  end

  it "una seconda scansione non duplica: aggiorna l'ultimo avvistamento" do
    record(now: 2.days.ago)
    expect { record(now: Time.current) }.not_to change(Vulnerabilities::Finding, :count)

    finding = Vulnerabilities::Finding.sole
    expect(finding.last_seen_at).to be_within(5.seconds).of(Time.current)
    expect(finding.first_seen_at).to be_within(5.seconds).of(2.days.ago)
  end

  it "la seconda scansione non riporta la riga come nuova" do
    record
    expect(record.value.opened).to be_empty
  end

  it "chiude ciò che non risulta più colpito" do
    record
    finding = Vulnerabilities::Finding.sole

    record({})

    expect(finding.reload).to be_status_resolved
    expect(finding.resolved_at).to be_present
  end

  it "una riga risolta che ricompare torna aperta (e senza data di chiusura)" do
    record
    record({})
    finding = Vulnerabilities::Finding.sole
    expect(finding.reload).to be_status_resolved

    record

    expect(finding.reload).to be_status_open
    expect(finding.resolved_at).to be_nil
  end

  it "una riga IGNORATA non viene né riaperta né richiusa: la decisione è di chi l'ha presa" do
    record
    finding = Vulnerabilities::Finding.sole
    finding.update!(status: :ignored, triage_note: "non raggiungibile")

    record        # ancora colpita
    expect(finding.reload).to be_status_ignored

    record({})    # non più colpita
    expect(finding.reload).to be_status_ignored
  end

  it "un pacchetto senza corrispondenze non genera nulla" do
    expect { record({}) }.not_to change(Vulnerabilities::Finding, :count)
  end

  it "lo stesso pacchetto in due manifest genera due righe distinte" do
    other_manifest = create(:vulnerability_manifest, project: project, path: "apps/api/Gemfile.lock")
    twin = create(:vulnerability_package, manifest: other_manifest, name: "rails", version: "7.0.0")

    record(matches, packages: [ package, twin ])

    expect(Vulnerabilities::Finding.count).to eq(2)
    expect(Vulnerabilities::Finding.pluck(:package_id)).to contain_exactly(package.id, twin.id)
  end

  it "un pacchetto colpito da più advisory apre una riga per ciascuno" do
    second = create(:vulnerability_advisory, :critical, osv_id: "GHSA-2")

    record({ package.osv_key => [ advisory, second ] })

    expect(Vulnerabilities::Finding.count).to eq(2)
  end

  it "non tocca i finding di un altro progetto" do
    other_finding = create(:vulnerability_finding)

    record({})

    expect(other_finding.reload).to be_status_open
  end

  it "conta quante restano aperte e quante ne ha chiuse" do
    record
    outcome = record({}).value

    expect(outcome.resolved_count).to eq(1)
    expect(outcome.still_open_count).to eq(0)
  end

  # CYRA-810 — un file delle dipendenze che la scansione non è riuscita a leggere non testimonia
  # nulla: chiudere le sue righe significherebbe far sparire una vulnerabilità perché abbiamo smesso
  # di guardarla. Resta fuori dalla riconciliazione finché una lettura riuscita non la smentisce.
  describe "file delle dipendenze non verificati" do
    let(:unread_manifest) { create(:vulnerability_manifest, :npm, :failing, project: project) }
    let(:unread_package) do
      create(:vulnerability_package, manifest: unread_manifest, name: "lodash", version: "4.17.15")
    end
    let!(:unread_finding) { create(:vulnerability_finding, project: project, package: unread_package) }

    it "non chiude le righe di un file che non ha potuto leggere" do
      record({}, unverified_manifest_ids: [ unread_manifest.id ])

      expect(unread_finding.reload).to be_status_open
      expect(unread_finding.resolved_at).to be_nil
    end

    it "chiude comunque le righe dei file letti davvero" do
      record
      verified_finding = Vulnerabilities::Finding.find_by!(package_id: package.id)

      record({}, unverified_manifest_ids: [ unread_manifest.id ])

      expect(verified_finding.reload).to be_status_resolved
    end

    it "dichiara nell'esito quanti file non ha potuto verificare" do
      outcome = record({}, unverified_manifest_ids: [ unread_manifest.id ]).value

      expect(outcome.unverified_count).to eq(1)
      expect(outcome.resolved_count).to eq(0)
    end

    it "senza file illeggibili l'esito non dichiara nulla di incompleto" do
      expect(record.value.unverified_count).to eq(0)
    end

    it "il file torna leggibile e non è più colpito: adesso la riga si chiude" do
      record({}, unverified_manifest_ids: [ unread_manifest.id ])

      record({}, packages: [ package, unread_package ])

      expect(unread_finding.reload).to be_status_resolved
    end
  end
end
