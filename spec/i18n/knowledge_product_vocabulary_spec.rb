# frozen_string_literal: true

require "rails_helper"

# CYRA-427 — lo stesso concetto cambiava nome da una schermata all'altra: quello che nel modulo di
# scrittura si chiamava «gruppo», nella matrice era un «prodotto» (è la stessa entità), e l'area si
# chiamava «Product», parola che non fa pensare alla documentazione. Le voci inglesi dentro
# un'interfaccia italiana si leggono come funzioni tecniche riservate.
RSpec.describe "Vocabolario di conoscenza e prodotto (CYRA-427)", type: :model do
  # CYRA-362 — il vincolo resta (le due schermate chiamano la stessa entità allo stesso modo), la
  # parola no: il nome deciso per l'insieme di progetti è «Gruppo», e vale ovunque — anche qui, dove
  # CYRA-427 aveva scelto «Prodotti». Il presidio per esteso sta in product_glossary_spec.rb.
  it "il modulo di scrittura e la matrice chiamano la stessa entità allo stesso modo" do
    I18n.with_locale(:it) do
      expect(I18n.t("member.knowledge.form.groups")).to eq("Gruppi")
      expect(I18n.t("member.product.matrices.columns.product")).to eq("Gruppo")
    end
  end

  it "le voci di menù dell'area sono in italiano" do
    I18n.with_locale(:it) do
      %w[knowledge book knowledge_review group_knowledge].each do |key|
        label = I18n.t("member.nav.#{key}")
        expect(label).not_to match(/\A(Knowledge|Book|Product)\z/), "#{key} è ancora in inglese: #{label}"
      end
    end
  end

  # CYRA-521 — l'area "Product" è diventata il gruppo "Conoscenza", e il gruppo che si chiamava
  # "Prodotto" dentro un'altra area ora è l'unico con quel nome: la collisione è chiusa (CYRA-330).
  it "il nome del gruppo contiene la parola che ne descrive il contenuto" do
    I18n.with_locale(:it) { expect(I18n.t("member.nav.group_knowledge")).to include("Conoscenza") }
  end

  it "«Raccolte» è il nome unico di quello che si chiamava Book" do
    I18n.with_locale(:it) do
      expect(I18n.t("member.nav.book")).to eq("Raccolte")
      expect(I18n.t("member.knowledge.books.title")).to eq("Raccolte")
    end
  end

  it "nessuna etichetta dell'area resta in inglese" do
    inglesi = []
    I18n.with_locale(:it) do
      walk = lambda do |node, path|
        case node
        when Hash then node.each { |key, value| walk.call(value, path + [ key.to_s ]) }
        when String then inglesi << path.join(".") if node.match?(/\A(Knowledge|Book|Books|Product)\z/)
        end
      end
      walk.call(I18n.t("member.knowledge"), %w[member knowledge])
      walk.call(I18n.t("member.nav"), %w[member nav])
    end
    expect(inglesi).to be_empty
  end
end
