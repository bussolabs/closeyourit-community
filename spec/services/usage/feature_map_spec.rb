# frozen_string_literal: true

require "rails_helper"

# CYRA-733 — il simbolo di rotta dice `Member::TicketsController#index`: è il nome di una classe, e
# per decidere cosa tenere e cosa togliere serve invece il nome della FUNZIONE. Qui si traduce il
# percorso di una pagina nella chiave stabile del catalogo, la stessa che l'assistente già usa.
RSpec.describe Usage::FeatureMap, type: :service do
  describe ".normalize" do
    it "sostituisce l'identificativo con il nome del segmento" do
      normalizzato = described_class.normalize("/member/tickets/7f3c-42",
                                               { controller: "member/tickets", action: "show", id: "7f3c-42" })

      expect(normalizzato).to eq("/member/tickets/:id")
    end

    it "sostituisce ogni identificativo di un percorso annidato" do
      normalizzato = described_class.normalize(
        "/member/projects/abc/documents/def",
        { controller: "member/project_documents", action: "edit", project_id: "abc", id: "def" }
      )

      expect(normalizzato).to eq("/member/projects/:project_id/documents/:id")
    end

    it "lascia intatto un percorso senza identificativi" do
      normalizzato = described_class.normalize("/member/tickets",
                                               { controller: "member/tickets", action: "index" })

      expect(normalizzato).to eq("/member/tickets")
    end

    it "non tocca il percorso per il formato della risposta" do
      normalizzato = described_class.normalize("/member/tickets",
                                               { controller: "member/tickets", action: "index", format: "turbo_stream" })

      expect(normalizzato).to eq("/member/tickets")
    end
  end

  describe ".key_for" do
    it "riconosce la funzione dall'elenco del catalogo" do
      expect(described_class.key_for("/member/tickets")).to eq("tickets")
    end

    it "una pagina dentro la funzione porta la chiave della funzione" do
      expect(described_class.key_for("/member/projects/:project_id/documents")).to eq("projects")
    end

    it "fra due funzioni annidate vince quella col percorso più lungo" do
      allow(described_class).to receive(:index).and_return("member/tickets" => "tickets", "member/tickets/list" => "list")
      described_class.instance_variable_set(:@max_depth, nil)

      expect(described_class.key_for("/member/tickets/list")).to eq("list")
    ensure
      described_class.instance_variable_set(:@max_depth, nil)
    end

    it "non confonde due funzioni che iniziano con la stessa parola" do
      expect(described_class.key_for("/member/personal/files")).to eq("personal_files")
      expect(described_class.key_for("/member/personal/secrets")).to eq("personal_variables")
    end

    it "un percorso fuori dal catalogo non ha chiave" do
      expect(described_class.key_for("/member/datasets")).to be_nil
    end

    it "la radice dell'area non è una funzione" do
      expect(described_class.key_for("/")).to be_nil
    end

    # La chiave finisce in una tabella con un formato dichiarato: una chiave nuova che non lo
    # rispettasse verrebbe scartata in silenzio dall'ingest, e la funzione risulterebbe mai vista.
    it "ogni chiave del catalogo rispetta il formato dei simboli" do
      chiavi = described_class.index.values

      expect(chiavi).to match_array(Assistant::BuildCatalog::FUNCTIONS.map { |f| f[:key] })
      expect(chiavi).to all(match(Usage::Symbol::SYMBOL_FORMAT))
    end
  end
end
