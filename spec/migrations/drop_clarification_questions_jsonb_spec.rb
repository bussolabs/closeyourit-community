# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260907200000_drop_clarification_questions_jsonb.rb")

# CYRA-784 — La migration che porta via l'archivio jsonb delle domande porta anche l'ultima passata
# di backfill, perché dopo il drop il testo non esiste più da nessuna parte. Queste prove guardano i
# due pezzi che nessun altro spec può vedere: la colonna non c'è più (lo schema vero), e la guardia
# che sta davanti al drop morde davvero su un giro rimasto indietro.
#
# La colonna si ricrea a mano dentro l'esempio: il database di test nasce da `schema.rb`, dove la
# colonna non esiste più. In PostgreSQL il DDL è transazionale, quindi la transazione dell'esempio la
# porta via da sola a fine prova.
RSpec.describe DropClarificationQuestionsJsonb do
  let(:connection) { ActiveRecord::Base.connection }

  it "lo schema non ha più l'archivio delle domande" do
    expect(connection.column_exists?("agents_clarifications", "questions")).to be(false)
  end

  describe "guardia davanti al drop" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    around do |example|
      verbose = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      connection.execute("ALTER TABLE agents_clarifications ADD COLUMN questions jsonb NOT NULL DEFAULT '[]'::jsonb")
      Agents::Clarification.reset_column_information
      example.run
    ensure
      connection.execute("ALTER TABLE agents_clarifications DROP COLUMN IF EXISTS questions")
      Agents::Clarification.reset_column_information
      ActiveRecord::Migration.verbose = verbose
    end

    def archivio!(clarification, domande)
      connection.execute(
        "UPDATE agents_clarifications SET questions = #{connection.quote(domande.to_json)}::jsonb " \
        "WHERE id = #{connection.quote(clarification.id)}"
      )
    end

    it "tace su un giro che ha già le sue righe di primo livello" do
      archivio!(create(:agent_clarification, workflow:, questions: [ "Quale ambiente?" ]), [ "Quale ambiente?" ])

      expect { described_class.new.send(:ensure_nothing_left_behind!) }.not_to raise_error
    end

    # Il caso che rende il drop irreversibile: domande nell'archivio, nessuna riga a cui sono state
    # portate. Cancellare la colonna qui vorrebbe dire perdere il testo per sempre.
    it "solleva su un giro con domande nell'archivio e nessuna riga, nominandolo" do
      clarification = create(:agent_clarification, workflow:, questions: [ "Rimasta indietro?" ])
      clarification.questions.delete_all
      archivio!(clarification, [ "Rimasta indietro?" ])

      expect { described_class.new.send(:ensure_nothing_left_behind!) }
        .to raise_error(described_class::ArchivioNonMigrato, /#{clarification.id}/)
    end

    it "non si ferma per un giro il cui archivio era già vuoto" do
      clarification = create(:agent_clarification, workflow:, questions: [ "Vuota?" ])
      clarification.questions.delete_all

      expect { described_class.new.send(:ensure_nothing_left_behind!) }.not_to raise_error
    end
  end
end
