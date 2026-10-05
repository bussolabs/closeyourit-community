# frozen_string_literal: true

require "rails_helper"

# CYRA-401 — I comandi CLI mostrati nel Vault («Usa questo segreto») vivono in UN SOLO punto: questo
# value object. Il test blinda le firme reali della CLI (`cyi run`, `cyi personal run`, `cyi secrets
# sync`, `use_cyi_personal`, env CLOSEYOURIT_TOKEN) e la regola d'oro: si interpolano solo nome
# progetto e ambiente, MAI un valore di secret.
RSpec.describe Secrets::UsageSnippets do
  describe "kind di progetto" do
    subject(:snippets) { described_class.new(kind: :project, project: "CYRA", environment: "production") }

    it "sul computer usa `cyi run` con progetto e ambiente compilati" do
      expect(snippets.local).to eq([ "cyi run -p CYRA -e production -- <command>" ])
    end

    it "per GitHub Actions sincronizza i valori sul repo con `cyi secrets sync`" do
      expect(snippets.ci_github).to eq([ "cyi secrets sync -p CYRA" ])
    end

    it "sugli altri sistemi di build inietta il token e poi esegue `cyi run`" do
      expect(snippets.ci_generic).to eq([
        "export CLOSEYOURIT_TOKEN=<token>",
        "cyi run -p CYRA -e production -- <command>"
      ])
    end

    it "sul server usa la stessa coppia token + `cyi run`" do
      expect(snippets.server).to eq([
        "export CLOSEYOURIT_TOKEN=<token>",
        "cyi run -p CYRA -e production -- <command>"
      ])
    end

    it "non è un kind personale e non offre la variante direnv" do
      expect(snippets).not_to be_personal
      expect(snippets.local_direnv).to be_nil
    end
  end

  describe "kind personale" do
    subject(:snippets) { described_class.new(kind: :personal) }

    it "sul computer usa `cyi personal run`" do
      expect(snippets.local).to eq([ "cyi personal run -- <command>" ])
    end

    it "offre l'alternativa direnv con `use_cyi_personal`" do
      expect(snippets.local_direnv).to eq([ "use_cyi_personal" ])
    end

    it "non ha una variante dedicata a GitHub Actions (i personali non si sincronizzano sul repo)" do
      expect(snippets.ci_github).to be_nil
    end

    it "sugli altri sistemi e sul server inietta il token e usa `cyi personal run`" do
      expected = [ "export CLOSEYOURIT_TOKEN=<token>", "cyi personal run -- <command>" ]
      expect(snippets.ci_generic).to eq(expected)
      expect(snippets.server).to eq(expected)
    end
  end

  describe "kind dell'organizzazione (shared)" do
    subject(:snippets) { described_class.new(kind: :shared) }

    it "usa i comandi di progetto con progetto e ambiente come segnaposto (va prima delegato a un progetto)" do
      expect(snippets.local).to eq([ "cyi run -p <project> -e <environment> -- <command>" ])
      expect(snippets.ci_github).to eq([ "cyi secrets sync -p <project>" ])
    end
  end

  describe "segnaposto e interpolazione" do
    it "senza progetto/ambiente usa i segnaposto leggibili" do
      snippets = described_class.new(kind: :project)
      expect(snippets.local).to eq([ "cyi run -p <project> -e <environment> -- <command>" ])
    end

    it "interpola progetto e ambiente e non contiene mai un valore di secret" do
      snippets = described_class.new(kind: :project, project: "ACME", environment: "staging")
      all_lines = (snippets.local + snippets.ci_github + snippets.ci_generic + snippets.server).join("\n")
      expect(all_lines).to include("ACME").and include("staging")
      # Solo nome progetto/ambiente + segnaposto: nessun valore in chiaro.
      expect(all_lines).not_to match(/=(?!<token>)\S*[a-z0-9]{8,}/i)
    end
  end

  describe "validazione" do
    it "rifiuta un kind sconosciuto" do
      expect { described_class.new(kind: :unknown) }.to raise_error(ArgumentError, /kind/)
    end
  end
end
