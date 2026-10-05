# frozen_string_literal: true

require "rails_helper"

# CYRA-453 — la pagina dichiarava la versione fissata ma non diceva quale versione stesse davvero
# usando ogni macchina: la domanda che motiva il pin («il rilascio è arrivato ovunque?») restava
# senza risposta. Qui si verifica il confronto, e soprattutto la sua PRUDENZA: ciò che le macchine
# dichiarano è testo libero, e un testo che non si sa leggere deve restare «non dichiarato», mai
# diventare un falso disallineamento.
RSpec.describe Agents::SkillBundleConformance do
  let(:organization) { create(:organization) }
  let(:bundle) do
    create(:agent_skill_bundle, organization:, repo: "bussolabs/closeyourit-skills",
                                ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)
  end

  def host_with(runtimes, hostname: "mac-uno")
    create(:agent_host, organization:, hostname:, runtimes:)
  end

  def runtime(name, version)
    { "name" => name, "present" => true, "version" => version, "required" => false }
  end

  describe "confronto con la versione fissata" do
    it "la stessa versione dichiarata → allineata" do
      host = host_with([ runtime("closeyourit-skills", "0.3.0") ])

      riga = described_class.new(bundle:, hosts: [ host ]).rows.first

      expect(riga.expected).to eq("0.3.0")
      expect(riga.actual).to eq("0.3.0")
      expect(riga).to be_aligned
    end

    it "una versione diversa → non allineata" do
      host = host_with([ runtime("closeyourit-skills", "0.1.0") ])

      riga = described_class.new(bundle:, hosts: [ host ]).rows.first

      expect(riga.actual).to eq("0.1.0")
      expect(riga).to be_mismatched
    end

    it "il nome del programma è riconosciuto senza badare a maiuscole o suffissi" do
      host = host_with([ runtime("CloseYourIt Skills bundle", "0.3.0") ])

      expect(described_class.new(bundle:, hosts: [ host ]).rows.first).to be_aligned
    end

    it "estrae il numero da una dichiarazione discorsiva (testo libero)" do
      host = host_with([ runtime("skills", "@bussolabs/closeyourit-skills/0.15.0") ])

      riga = described_class.new(bundle:, hosts: [ host ]).rows.first

      expect(riga.actual).to eq("0.15.0")
      expect(riga).to be_mismatched
    end

    it "confronta anche quando la versione fissata porta la v davanti" do
      pin = create(:agent_skill_bundle, organization:, repo: "bussolabs/closeyourit-skills",
                                        ref: "v1.2.0", version: "v1.2.0", digest: "d" * 12)
      host = host_with([ runtime("skills", "1.2.0") ])

      expect(described_class.new(bundle: pin, hosts: [ host ]).rows.first).to be_aligned
    end
  end

  describe "prudenza: quando non si sa, non si accusa" do
    it "nessun programma delle competenze dichiarato → non dichiarata" do
      host = host_with([ runtime("node", "22.1.0") ])

      riga = described_class.new(bundle:, hosts: [ host ]).rows.first

      expect(riga.actual).to be_nil
      expect(riga).to be_unknown
      expect(riga).not_to be_mismatched
    end

    it "una dichiarazione senza numeri → non dichiarata, non un disallineamento" do
      host = host_with([ runtime("skills", "sconosciuta") ])

      expect(described_class.new(bundle:, hosts: [ host ]).rows.first).to be_unknown
    end

    it "il programma è dichiarato assente sulla macchina → non dichiarata" do
      host = host_with([ { "name" => "skills", "present" => false, "version" => nil, "required" => false } ])

      expect(described_class.new(bundle:, hosts: [ host ]).rows.first).to be_unknown
    end

    it "senza versione fissata non si giudica nessuna macchina" do
      host = host_with([ runtime("skills", "0.3.0") ])

      riga = described_class.new(bundle: nil, hosts: [ host ]).rows.first

      expect(riga.expected).to be_nil
      expect(riga.actual).to eq("0.3.0")
      expect(riga).to be_unknown
    end
  end

  describe "elenco e conteggi" do
    it "una riga per macchina, in ordine di nome" do
      terza = host_with([], hostname: "mac-tre")
      prima = host_with([], hostname: "mac-due")

      righe = described_class.new(bundle:, hosts: [ terza, prima ]).rows

      expect(righe.map { |riga| riga.host.hostname }).to eq(%w[mac-due mac-tre])
    end

    it "conta le macchine allineate, quelle non allineate e quelle che non dichiarano" do
      allineata = host_with([ runtime("skills", "0.3.0") ], hostname: "mac-a")
      vecchia = host_with([ runtime("skills", "0.1.0") ], hostname: "mac-b")
      muta = host_with([], hostname: "mac-c")

      conformita = described_class.new(bundle:, hosts: [ allineata, vecchia, muta ])

      expect(conformita.aligned_count).to eq(1)
      expect(conformita.mismatched_count).to eq(1)
      expect(conformita.unknown_count).to eq(1)
      expect(conformita).to be_any
    end

    it "senza macchine registrate l'elenco è vuoto" do
      conformita = described_class.new(bundle:, hosts: [])

      expect(conformita.rows).to be_empty
      expect(conformita).not_to be_any
    end
  end
end
