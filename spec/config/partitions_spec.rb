# frozen_string_literal: true

require "rails_helper"

# CYRA-750 — le fette vivono in tre posti che devono restare d'accordo: il catalogo
# (Ops::Partitions), il dump dello schema che NON deve contenerle, e il giro notturno che le prepara.
# Se uno dei tre si sfila, il guasto non si vede subito: si vede quando un database ricostruito
# rifiuta la prima scrittura, o quando arriva un mese senza la sua fetta.
RSpec.describe "Le fette delle tabelle di telemetria", type: :model do
  let(:schema) { Rails.root.join("db/schema.rb").read }
  let(:recurring) { YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production") }

  describe "il dump dello schema" do
    it "descrive ogni tabella padre come divisa a fette" do
      Ops::Partitions::TABLES.each do |tabella|
        expect(schema).to include(%(create_table "#{tabella.name}", primary_key: ["id", "#{tabella.key}"], ) +
                                  %(options: "PARTITION BY RANGE (#{tabella.key})")),
                          "#{tabella.name} non risulta divisa a fette in db/schema.rb"
      end
    end

    # Il dumper le riscriverebbe con `INHERITS`, che è l'ereditarietà vecchia di PostgreSQL e non una
    # fetta: un database ricostruito da quel dump avrebbe tabelle padre vuote e fette scollegate.
    it "non contiene nessuna fetta" do
      fette = schema.scan(/create_table "([a-z_]+)"/).flatten
                    .select { |nome| Ops::Partitions.dumper_ignore_pattern.match?(nome) }

      expect(fette).to be_empty, "db/schema.rb contiene le fette #{fette.join(', ')}: " \
                                 "controlla config/initializers/partitions.rb"
    end

    it "le tiene fuori dichiarandolo, non per caso" do
      expect(ActiveRecord::SchemaDumper.ignore_tables).to include(Ops::Partitions.dumper_ignore_pattern)
    end
  end

  describe "la regola che riconosce una fetta" do
    it "riconosce le fette mensili e quella di riserva di ogni tabella" do
      nomi = Ops::Partitions.table_names.flat_map do |tabella|
        [ Ops::Partitions.partition_name(tabella, Time.current), Ops::Partitions.default_partition_name(tabella) ]
      end

      expect(nomi).to all(match(Ops::Partitions.dumper_ignore_pattern))
    end

    it "non scambia per fetta una tabella vera" do
      expect(Ops::Partitions.dumper_ignore_pattern).not_to match("logs_entries")
      expect(Ops::Partitions.dumper_ignore_pattern).not_to match("logs_links")
    end
  end

  describe "il giro notturno" do
    it "prepara le fette prima che le potature stacchino quelle scadute" do
      expect(recurring.dig("ensure_partitions", "class")).to eq("Ops::EnsurePartitionsJob")
      expect(recurring.dig("ensure_partitions", "schedule")).to eq("every day at 1am")
    end
  end
end
