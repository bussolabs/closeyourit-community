# frozen_string_literal: true

require "rails_helper"

# CYRA-470 — i gruppi (etichette libere) con cui organizzare la flotta: "produzione", "staging", "CI".
# Servono a filtrare e a leggere l'elenco per sezioni, così la domanda «come sta la produzione» si può
# fare senza scorrere tutte le macchine.
RSpec.describe "Servers::Host gruppi (CYRA-470)", type: :model do
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, organization:) }

  describe "normalizzazione" do
    it "accetta l'elenco come testo, separatori virgola o a capo, e ripulisce" do
      host.update!(groups: [ "produzione, staging\n produzione " ])

      expect(host.groups).to eq(%w[produzione staging])
    end

    it "senza gruppi resta una lista vuota, mai nil" do
      expect(host.groups).to eq([])
    end

    it "tiene al massimo un numero ragionevole di gruppi" do
      many = (1..(Servers::Host::GROUPS_MAX + 5)).map { |n| "gruppo-#{n}" }
      host.update!(groups: many)

      expect(host.groups.size).to eq(Servers::Host::GROUPS_MAX)
    end
  end

  describe "validazione" do
    it "rifiuta un'etichetta troppo lunga" do
      host.groups = [ "x" * (Servers::Host::GROUP_MAX_LENGTH + 1) ]

      expect(host).not_to be_valid
      expect(host.errors[:groups]).to be_present
    end

    it "accetta un'etichetta corta come «CI»" do
      host.groups = [ "CI" ]

      expect(host).to be_valid
    end
  end

  describe ".in_group" do
    it "trova solo le macchine di quel gruppo" do
      prod = create(:server_host, organization:, groups: [ "produzione" ])
      multi = create(:server_host, organization:, groups: [ "produzione", "database" ])
      create(:server_host, organization:, groups: [ "staging" ])

      expect(Servers::Host.in_group("produzione")).to contain_exactly(prod, multi)
    end
  end

  describe ".group_counts_for" do
    it "conta le macchine per gruppo, contando un host in ogni suo gruppo, in ordine" do
      create(:server_host, organization:, groups: [ "produzione" ])
      create(:server_host, organization:, groups: [ "produzione", "database" ])
      create(:server_host, organization:, groups: [ "staging" ])
      create(:server_host, organization:, groups: [])

      counts = Servers::Host.group_counts_for(organization.server_hosts)

      expect(counts).to eq("database" => 1, "produzione" => 2, "staging" => 1)
    end

    it "senza gruppi da nessuna parte torna vuoto" do
      create(:server_host, organization:, groups: [])

      expect(Servers::Host.group_counts_for(organization.server_hosts)).to eq({})
    end
  end
end
