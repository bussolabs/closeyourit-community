# frozen_string_literal: true

require "rails_helper"

# Parity delle chiavi i18n del sito marketing: EN è la fonte di verità, IT deve avere ESATTAMENTE
# lo stesso set di chiavi (niente fallback silenziosi in pagina, regola rules/i18n.md).
RSpec.describe "i18n sito marketing", type: :model do
  PARITY_DIRS = %w[config/locales/website config/locales/routes].freeze

  def flatten_keys(hash, prefix = nil)
    hash.flat_map do |key, value|
      full = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? flatten_keys(value, full) : [ full ]
    end
  end

  def keys_for(locale)
    PARITY_DIRS.flat_map { |dir| Dir[Rails.root.join(dir, "**", "*.yml")] }
                .map { |file| YAML.load_file(file) }
                .select { |data| data.key?(locale) }
                .flat_map { |data| flatten_keys(data.fetch(locale)) }
                .sort
  end

  it "en e it espongono lo stesso set di chiavi (website + routes)" do
    en = keys_for("en")
    it_keys = keys_for("it")

    expect(en).not_to be_empty
    expect(it_keys - en).to eq([]), "chiavi presenti solo in it: #{(it_keys - en).join(', ')}"
    expect(en - it_keys).to eq([]), "chiavi presenti solo in en: #{(en - it_keys).join(', ')}"
  end

  it "ogni feature del catalogo ha il proprio blocco di copy in entrambi i locali" do
    Website::FeaturePage.all.each do |page|
      %w[en it].each do |locale|
        %w[name card title meta_description heading summary points].each do |field|
          value = I18n.t("website.features.#{page.key}.#{field}", locale: locale, raise: true)
          expect(value).to be_present
        end
      end
    end
  end
end
