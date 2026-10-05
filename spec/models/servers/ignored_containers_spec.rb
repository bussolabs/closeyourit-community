# frozen_string_literal: true

require "rails_helper"

# CYRA-489 — l'avviso «container caduto» scattava sul lavoro normale delle build: i container di
# compilazione e test nascono e muoiono a ogni lavorazione, e l'unica difesa era spegnere l'intera
# regola, perdendo anche i guasti veri.
RSpec.describe "Container che non sono servizi", type: :model do
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, organization:) }

  describe "Servers::Host#ignored_container?" do
    it "riconosce un frammento del nome, senza distinzione di maiuscole" do
      host.update!(ignored_container_patterns: [ "ci-runner" ])

      expect(host.ignored_container?("ci-runner-postgres-17")).to be(true)
      expect(host.ignored_container?("CI-Runner-redis")).to be(true)
      expect(host.ignored_container?("closeyourit-web")).to be(false)
    end

    it "accetta l'elenco come testo, una riga per frammento" do
      host.update!(ignored_container_patterns: [ "ci-runner\ntest-postgres , buildx-cache " ])

      expect(host.ignored_container_patterns).to eq(%w[ci-runner test-postgres buildx-cache])
    end

    it "rifiuta un frammento troppo corto, che nasconderebbe anche i servizi veri" do
      host.ignored_container_patterns = [ "ab" ]

      expect(host).not_to be_valid
      expect(host.errors[:ignored_container_patterns]).to be_present
    end
  end

  describe "Servers::ContainerSample.expected_names_for" do
    def sample(name)
      create(:server_container_sample, host:, name:, running: true, idle_managed: false, recorded_at: 1.minute.ago)
    end

    it "non si aspetta i container esclusi dalla macchina" do
      sample("closeyourit-web")
      sample("ci-runner-postgres")
      host.update!(ignored_container_patterns: [ "ci-runner" ])

      expect(described_class_names).to eq(%w[closeyourit-web])
    end

    it "non si aspetta i builder di compilazione, che spariscono per costruzione" do
      sample("closeyourit-web")
      sample("buildx_buildkit_default")

      expect(described_class_names).to eq(%w[closeyourit-web])
    end

    def described_class_names = Servers::ContainerSample.expected_names_for(host).sort
  end
end
