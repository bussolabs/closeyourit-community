# frozen_string_literal: true

require "rails_helper"

# Gli indici unici sui nomi devono dire la stessa cosa delle validazioni del modello, che sono
# case-insensitive: con un indice sul nome grezzo due richieste concorrenti potrebbero creare
# "Auth" e "auth" nello stesso prodotto, e la matrice mostrerebbe due righe per la stessa cosa.
RSpec.describe "Indici della matrice funzionalità", type: :model do
  def unique_expression_index(table)
    ActiveRecord::Base.connection.indexes(table).find { |i| i.unique && i.columns.is_a?(String) }
  end

  it "product_categories è unica su [gruppo, nome minuscolo]" do
    index = unique_expression_index("product_categories")

    expect(index).to be_present
    expect(index.columns).to include("group_id", "lower")
  end

  it "product_features è unica su [categoria, nome minuscolo]" do
    index = unique_expression_index("product_features")

    expect(index).to be_present
    expect(index.columns).to include("category_id", "lower")
  end

  it "il database rifiuta due categorie che differiscono solo per le maiuscole" do
    category = create(:product_category, name: "Auth")
    duplicate = build(:product_category, group: category.group, organization: category.organization, name: "auth")

    # save(validate: false) salta la validazione del modello: qui si prova l'ultima difesa.
    expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "il database rifiuta due funzionalità che differiscono solo per le maiuscole" do
    feature = create(:product_feature, name: "2FA")
    duplicate = build(:product_feature, category: feature.category, organization: feature.organization, name: "2fa")

    expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
