# frozen_string_literal: true

require "rails_helper"
require "digest"

# CYRA-723 — la provenienza dei bundle vendorizzati non può restare scollegata.
#
# Ogni contratto wire vive in copia qui dentro (`contracts/<nome>/v<N>/`) e il `LOCK.json` accanto
# dice DA DOVE quella copia arriva: il commit di `closeyourit-docs` che la contiene byte per byte.
# Con `commit: null` la copia non è più confrontabile con niente — CYRA-108 l'ha lasciata così per
# poter patchare in anticipo, e per settimane nessun controllo se n'è accorto: le quattro librerie
# client sono rimaste ferme a una copia più vecchia e il server a una più nuova, senza che la
# differenza avesse un posto dove diventare rossa.
#
# Il workflow riusabile `contracts-sync.yml` di closeyourit-docs verifica la stessa cosa con la
# storia vera del repository canonico sotto mano; questa spec è la metà che gira senza rete e senza
# token, e presidia l'unica forma di sregolatezza che qui possiamo vedere da soli: un LOCK senza
# riferimento, o che non descrive il bundle che gli sta accanto.
RSpec.describe "Provenienza dei contratti vendorizzati" do
  let(:contracts_root) { Rails.root.join("contracts") }
  let(:locks) { contracts_root.glob("*/LOCK*.json").sort }

  # `contracts/ingest/LOCK.json` → "contracts/ingest/LOCK.json", per messaggi leggibili.
  def relative(path) = path.relative_path_from(Rails.root).to_s

  def lock_data(path) = JSON.parse(path.read)

  it "trova almeno un contratto vendorizzato da presidiare" do
    expect(locks).not_to be_empty, "nessun LOCK.json sotto contracts/: la spec starebbe verificando il vuoto"
  end

  it "pinna ogni copia a un commit del repository canonico" do
    aggregate_failures do
      locks.each do |path|
        commit = lock_data(path)["commit"]

        expect(commit).to be_a(String).and(match(/\A[0-9a-f]{7,40}\z/)),
                          "#{relative(path)}: commit=#{commit.inspect} — una copia senza riferimento non è " \
                          "confrontabile con il contratto canonico, e la deriva resta invisibile"
      end
    end
  end

  it "dichiara closeyourit-docs come repository di provenienza" do
    aggregate_failures do
      locks.each do |path|
        expect(lock_data(path)["repository"]).to eq("https://github.com/bussolabs/closeyourit-docs"),
                                                 relative(path)
      end
    end
  end

  it "nomina il contratto con la cartella che sta pinnando" do
    aggregate_failures do
      locks.each do |path|
        contract = lock_data(path)["contract"]
        name, version = contract.to_s.split("/", 2)

        expect(name).to eq(path.dirname.basename.to_s), relative(path)
        expect(path.dirname.join(version.to_s)).to be_directory,
                                                   "#{relative(path)}: contract=#{contract.inspect} ma la cartella non esiste"
      end
    end
  end

  it "porta il digest dello SHA256SUMS che protegge il bundle" do
    aggregate_failures do
      locks.each do |path|
        version = lock_data(path).fetch("contract").split("/").last
        sums = path.dirname.join(version, "SHA256SUMS")

        expect(Digest::SHA256.hexdigest(sums.read)).to eq(lock_data(path)["sha256sums"]), relative(path)
      end
    end
  end

  # Un bundle copiato senza il suo LOCK è lo stesso difetto visto da un'altra parte: la copia c'è,
  # la provenienza no.
  it "non lascia nessuna versione vendorizzata senza il proprio LOCK" do
    pinned = locks.group_by { |path| path.dirname }
                  .transform_values { |group| group.map { |lock| lock_data(lock)["contract"] }.compact.sort }

    aggregate_failures do
      contracts_root.glob("*/v*").select(&:directory?).group_by(&:dirname).each do |dir, versions|
        expected = versions.map { |path| "#{dir.basename}/#{path.basename}" }.sort

        expect(pinned.fetch(dir, [])).to match_array(expected),
                                         "#{relative(dir)}: versioni vendorizzate #{expected.inspect}, pinnate #{pinned.fetch(dir, []).inspect}"
      end
    end
  end
end
