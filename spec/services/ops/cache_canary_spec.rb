# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::CacheCanary, type: :service do
  # In test Rails.cache è un null_store (config/environments/test.rb): non trattiene nulla, quindi un
  # round-trip reale fallirebbe sempre. Iniettiamo lo store dello scenario così il canarino è verificato
  # contro un comportamento noto, non contro la cache di test.
  def with_cache(store)
    allow(Rails).to receive(:cache).and_return(store)
  end

  describe ".call" do
    it "available quando il valore scritto si rilegge identico (round-trip integro)" do
      with_cache(ActiveSupport::Cache::MemoryStore.new)

      result = described_class.call

      expect(result).to be_available
      expect(result.error).to be_nil
    end

    # Cache che ACCETTA le scritture ma non le trattiene (null store / lock silenzioso): la write non
    # solleva, ma la rilettura non torna il valore → il canarino la riconosce comunque come giù.
    it "unavailable quando la rilettura non torna il valore scritto (scrittura ingoiata)" do
      with_cache(ActiveSupport::Cache::NullStore.new)

      result = described_class.call

      expect(result).not_to be_available
      expect(result.error).to include("round-trip fallito")
    end

    # Il dettaglio deve dire cosa ha scritto e cosa ha riletto: è ciò che finisce nel log per la diagnosi.
    it "riporta nel dettaglio il token scritto e il valore riletto" do
      with_cache(ActiveSupport::Cache::NullStore.new)

      result = described_class.call(token: "abc123")

      expect(result.error).to include("abc123").and include("nil")
    end

    # Cache che SOLLEVA sulla scrittura (connessione persa, lock che erutta un'eccezione): il canarino
    # cattura, segnala giù e NON propaga — il giro periodico non deve fallire né ritentare.
    it "unavailable senza propagare quando la scrittura solleva" do
      store = ActiveSupport::Cache::MemoryStore.new
      allow(store).to receive(:write).and_raise(ActiveRecord::StatementInvalid.new("database is locked"))
      with_cache(store)

      result = nil
      expect { result = described_class.call }.not_to raise_error
      expect(result).not_to be_available
      expect(result.error).to include("ActiveRecord::StatementInvalid").and include("locked")
    end
  end
end
