# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::SyncPackages do
  let(:repository) { create(:github_repository) }
  let(:project) { repository.project }
  let(:manifest) do
    create(:vulnerability_manifest, :unread, project: project, path: "Gemfile.lock",
                                             blob_sha: "sha-abc")
  end
  let(:client) { instance_double(Github::Client) }
  let(:lockfile) { Rails.root.join("spec/fixtures/vulnerabilities/gemfile_lock.txt").read }

  def sync(target = manifest, now: Time.current)
    described_class.call(manifest: target, client: client, now: now)
  end

  it "scarica il lockfile per sha e ne scrive i pacchetti" do
    allow(client).to receive(:blob).and_return(lockfile)

    result = sync

    expect(result).to be_ok
    expect(manifest.packages.pluck(:name)).to include("rails", "actionpack", "concurrent-ruby")
    expect(client).to have_received(:blob)
      .with(repository.installation.installation_id, repository.full_name, "sha-abc")
  end

  it "eredita l'ecosistema dal manifest e marca le dirette" do
    allow(client).to receive(:blob).and_return(lockfile)

    sync

    expect(manifest.packages.pluck(:ecosystem).uniq).to eq([ "RubyGems" ])
    expect(manifest.packages.find_by(name: "rails")).to be_direct
    expect(manifest.packages.find_by(name: "concurrent-ruby")).not_to be_direct
  end

  it "registra il digest e il momento della lettura" do
    allow(client).to receive(:blob).and_return(lockfile)

    sync

    manifest.reload
    expect(manifest.content_digest).to eq(Vulnerabilities::Manifest.digest_for(lockfile))
    expect(manifest.scanned_at).to be_present
    expect(manifest.packages_count).to eq(manifest.packages.count)
  end

  it "un lockfile immutato non si riparsa, ma i suoi pacchetti restano disponibili" do
    allow(client).to receive(:blob).and_return(lockfile)
    sync
    count = manifest.packages.count
    ids = manifest.packages.pluck(:id)

    result = sync(manifest.reload)

    expect(result.value.size).to eq(count)
    # Nessuna riga ricreata: sono gli stessi record di prima.
    expect(manifest.packages.pluck(:id)).to match_array(ids)
  end

  it "un lockfile cambiato sostituisce i pacchetti, non li accumula" do
    allow(client).to receive(:blob).and_return(lockfile)
    sync
    reduced = "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.0.1)\n\nDEPENDENCIES\n  rails\n"
    allow(client).to receive(:blob).and_return(reduced)

    sync(manifest.reload)

    expect(manifest.packages.pluck(:name, :version)).to eq([ [ "rails", "7.0.1" ] ])
  end

  it "un lockfile illeggibile si scrive sul manifest e non ferma il resto" do
    allow(client).to receive(:blob).and_return("non è un lockfile")

    result = sync

    expect(result).to be_err
    expect(result.error.code).to eq("R422-VULN-003")
    expect(manifest.reload.parse_error).to be_present
    expect(manifest.scanned_at).to be_present
  end

  it "un manifest che aveva fallito viene ritentato anche a digest invariato" do
    allow(client).to receive(:blob).and_return(lockfile)
    digest = Vulnerabilities::Manifest.digest_for(lockfile)
    manifest.update!(content_digest: digest, parse_error: "no_specs_parsed")

    result = sync(manifest.reload)

    expect(result).to be_ok
    expect(manifest.reload.parse_error).to be_nil
    expect(manifest.packages).to be_present
  end

  it "un blob sparito è un errore dichiarato" do
    allow(client).to receive(:blob).and_return(nil)

    result = sync

    expect(result).to be_err
    expect(result.error.code).to eq("R404-VULN-001")
  end

  # CYRA-810 — chi legge il manifest deve poter distinguere «letto e pulito» da «non letto». Senza
  # questo segno un contenuto sparito o un GitHub muto passavano per una lettura riuscita a vuoto.
  it "un blob sparito segna il manifest come non verificato" do
    allow(client).to receive(:blob).and_return(nil)

    sync

    expect(manifest.reload.parse_error).to be_present
    expect(manifest.scanned_at).to be_present
  end

  it "GitHub che non risponde segna il manifest come non verificato" do
    allow(client).to receive(:blob)
      .and_raise(Github::Client::Error.new("giù", code: "R502-GITHUB-001"))

    result = sync

    expect(result).to be_err
    expect(result.error.code).to eq("R502-GITHUB-001")
    expect(manifest.reload.parse_error).to be_present
  end

  it "senza sha del blob il manifest resta segnato come non verificato" do
    manifest.update!(blob_sha: nil)

    sync(manifest.reload)

    expect(manifest.reload.parse_error).to be_present
  end

  it "un lockfile enorme non viene parsato" do
    stub_const("Vulnerabilities::Constants::MAX_MANIFEST_BYTES", 10)
    allow(client).to receive(:blob).and_return(lockfile)

    result = sync

    expect(result).to be_err
    expect(result.error.code).to eq("R422-VULN-004")
    expect(manifest.reload.parse_error).to eq("too_large")
  end

  it "senza sha del blob non si prova nemmeno a scaricare" do
    manifest.update!(blob_sha: nil)
    expect(client).not_to receive(:blob)

    expect(sync(manifest.reload)).to be_err
  end

  it "una versione duplicata nello stesso lockfile non rompe l'unicità" do
    duplicated = "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.0.1)\n    rails (7.0.1)\n\nDEPENDENCIES\n  rails\n"
    allow(client).to receive(:blob).and_return(duplicated)

    expect(sync).to be_ok
    expect(manifest.packages.count).to eq(1)
  end

  describe "identità dei pacchetti fra una lettura e l'altra" do
    # Due letture dello stesso file in cui cambia UNA sola dipendenza: è il caso del ticket.
    let(:before_lock) do
      <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            actionpack (7.0.0)
            concurrent-ruby (1.2.2)
            rails (7.0.0)
              actionpack (= 7.0.0)

        DEPENDENCIES
          rails (= 7.0.0)
      LOCK
    end
    let(:after_lock) { before_lock.sub("concurrent-ruby (1.2.2)", "concurrent-ruby (1.3.0)") }

    def read(content)
      allow(client).to receive(:blob).and_return(content)
      sync(manifest.reload)
    end

    it "un pacchetto rimasto uguale resta la stessa riga, non una nuova" do
      read(before_lock)
      untouched = manifest.packages.where(name: %w[actionpack rails]).pluck(:id)

      read(after_lock)

      expect(manifest.packages.where(name: %w[actionpack rails]).pluck(:id)).to match_array(untouched)
    end

    it "una vulnerabilità ignorata su un pacchetto invariato conserva decisione e storico" do
      read(before_lock)
      finding = create(:vulnerability_finding, :ignored,
                       package: manifest.packages.find_by!(name: "actionpack"),
                       first_seen_at: 10.days.ago)

      read(after_lock)

      expect(finding.reload).to be_status_ignored
      expect(finding.triage_note).to be_present
      expect(finding.first_seen_at).to be_within(1.second).of(10.days.ago)
    end

    it "una vulnerabilità collegata a un ticket non perde il collegamento" do
      read(before_lock)
      finding = create(:vulnerability_finding, :promoted,
                       package: manifest.packages.find_by!(name: "actionpack"))
      ticket_id = finding.ticket_id

      read(after_lock)

      expect(finding.reload.ticket_id).to eq(ticket_id)
    end

    it "una dipendenza diventata diretta si aggiorna sul posto" do
      read(before_lock)
      actionpack = manifest.packages.find_by!(name: "actionpack")
      declared = before_lock.sub("  rails (= 7.0.0)\n", "  actionpack\n  rails (= 7.0.0)\n")

      read(declared)

      expect(actionpack.reload).to be_direct
      expect(manifest.packages.find_by!(name: "actionpack").id).to eq(actionpack.id)
    end

    it "un pacchetto sparito dal lockfile se ne va, e con lui la sua vulnerabilità" do
      read(before_lock)
      finding = create(:vulnerability_finding,
                       package: manifest.packages.find_by!(name: "concurrent-ruby"))

      read(before_lock.sub("    concurrent-ruby (1.2.2)\n", ""))

      expect(manifest.packages.pluck(:name)).to match_array(%w[actionpack rails])
      expect(Vulnerabilities::Finding.exists?(finding.id)).to be(false)
    end

    it "una versione aggiornata è un pacchetto diverso: quello vecchio esce" do
      read(before_lock)
      old = manifest.packages.find_by!(name: "concurrent-ruby")

      read(after_lock)

      expect(Vulnerabilities::Package.exists?(old.id)).to be(false)
      expect(manifest.packages.find_by!(name: "concurrent-ruby").version).to eq("1.3.0")
    end

    it "il conteggio dei pacchetti segue la riconciliazione" do
      read(before_lock)

      read(before_lock.sub("    concurrent-ruby (1.2.2)\n", ""))

      expect(manifest.reload.packages_count).to eq(2)
      expect(manifest.packages.count).to eq(2)
    end

    it "due file dello stesso progetto restano indipendenti" do
      other = create(:vulnerability_manifest, :unread, project: project, path: "web/Gemfile.lock",
                                                       blob_sha: "sha-web")
      allow(client).to receive(:blob).and_return(before_lock)
      sync(other)
      untouched = other.packages.pluck(:id)
      read(before_lock)

      read(before_lock.sub("    concurrent-ruby (1.2.2)\n", ""))

      expect(other.reload.packages.pluck(:id)).to match_array(untouched)
      expect(other.packages.count).to eq(3)
    end

    it "un lockfile diventato illeggibile non cancella pacchetti né decisioni" do
      read(before_lock)
      finding = create(:vulnerability_finding, :ignored,
                       package: manifest.packages.find_by!(name: "actionpack"))

      result = read("non è un lockfile")

      expect(result).to be_err
      expect(manifest.reload.packages.count).to eq(3)
      expect(finding.reload).to be_status_ignored
    end
  end
end
