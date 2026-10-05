# frozen_string_literal: true

require "rails_helper"

# CYRA-497 — «translation missing: it.member.metrics.col_environment» in mezzo a una tabella: una
# voce esisteva in inglese e non in italiano, e il prodotto mostrava il segnaposto di i18n a chi
# legge. Il difetto non si vede scrivendo la chiave — si vede solo confrontando le due lingue.
#
# Qui si confrontano le chiavi dell'interfaccia (non i cataloghi di terze parti come faker, né i
# default di Rails): ogni voce deve esistere in entrambe le lingue. Manca una traduzione? Fallisce
# qui, non davanti a un cliente.
RSpec.describe "Le due lingue coprono le stesse voci", type: :model do
  # Prefissi dell'interfaccia del prodotto. `valhalla.` è la console interna e `website.` il sito
  # pubblico: hanno la loro guardia (website_parity_spec) e regole diverse.
  PRODUCT_PREFIXES = %w[member. shared. ui. auth. cli. notifications. mailer. reports.].freeze

  def keys_for(locale)
    flatten(I18n.backend.send(:translations).fetch(locale), "", {}).keys
      .select { |key| key.start_with?(*PRODUCT_PREFIXES) }
  end

  def flatten(node, prefix, out)
    node.each do |key, value|
      value.is_a?(Hash) ? flatten(value, "#{prefix}#{key}.", out) : out["#{prefix}#{key}"] = value
    end
    out
  end

  before { I18n.eager_load! }

  it "nessuna voce dell'interfaccia esiste solo in inglese" do
    expect(keys_for(:en) - keys_for(:it)).to be_empty
  end

  it "nessuna voce dell'interfaccia esiste solo in italiano" do
    expect(keys_for(:it) - keys_for(:en)).to be_empty
  end
end
