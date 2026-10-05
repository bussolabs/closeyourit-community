# frozen_string_literal: true

require "rails_helper"

RSpec.describe Text::BackfillOrthography do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  # I record storici sono nati PRIMA delle `normalizes`, e ricrearli non è banale: `normalizes` di
  # Rails decora il TIPO dell'attributo, quindi anche `update_columns` e `update_all` ripasserebbero
  # la correzione. L'unico modo di rimettere in tabella un testo senza accenti è la UPDATE grezza.
  def with_raw(record, **columns)
    connection = record.class.connection
    assignments = columns.map do |column, value|
      "#{connection.quote_column_name(column)} = #{connection.quote(value.is_a?(String) ? value : value.to_json)}"
    end
    connection.update(<<~SQL.squish)
      UPDATE #{record.class.quoted_table_name} SET #{assignments.join(', ')}
      WHERE id = #{connection.quote(record.id)}
    SQL
    record.reload
  end

  describe "#call" do
    it "corregge la descrizione e l'analisi tecnica dei ticket storici" do
      ticket = with_raw(create(:ticket, organization:, project:),
                        description: "nasce gia in stato saltata, che e' definitivo",
                        technical_analysis: "la ereditarieta non e' rispettata")

      described_class.call(dry_run: false)

      expect(ticket.reload.description).to eq("nasce già in stato saltata, che è definitivo")
      expect(ticket.technical_analysis).to eq("la ereditarietà non è rispettata")
    end

    it "corregge i commenti storici" do
      comment = with_raw(create(:ticket_comment, organization:), body: "Se ne e' accorto")

      described_class.call(dry_run: false)

      expect(comment.reload.body).to eq("Se ne è accorto")
    end

    it "corregge gli scenari e le condizioni storiche" do
      ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
      scenario = with_raw(create(:ticketing_scenario, ticket:), step_expected: "la notifica e' rimandata")
      condition = with_raw(create(:ticketing_condition, ticket:), text: "la mail e' partita")

      described_class.call(dry_run: false)

      expect(scenario.reload.step_expected).to eq("la notifica è rimandata")
      expect(condition.reload.text).to eq("la mail è partita")
    end

    it "corregge i piani degli agenti, jsonb compresi" do
      ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
      attempt = create(:agent_attempt, organization:, workflow: ticket.agent_workflow)
      plan = Agents::Plan.create!(workflow: ticket.agent_workflow, attempt:, ticket_snapshot_digest: "x",
                                  technical_analysis: "Piano", scenarios: [], definition_of_done: [], notes: [])
      with_raw(plan, technical_analysis: "la ereditarieta e' rotta", notes: [ "serve gia il worker" ])

      described_class.call(dry_run: false)

      expect(plan.reload.technical_analysis).to eq("la ereditarietà è rotta")
      expect(plan.notes).to eq([ "serve già il worker" ])
    end

    it "in dry run non scrive niente ma conta lo stesso" do
      ticket = with_raw(create(:ticket, organization:, project:), description: "e' gia rotto")

      result = described_class.call

      expect(ticket.reload.description).to eq("e' gia rotto")
      expect(result.value.fetch("Ticketing::Ticket")[:corrected]).to eq(1)
    end

    it "riporta quanti record ha guardato e quanti ne ha corretti" do
      with_raw(create(:ticket, organization:, project:), description: "e' rotto")
      create(:ticket, organization:, project:, description: "tutto a posto")

      report = described_class.call(dry_run: false).value.fetch("Ticketing::Ticket")

      expect(report[:scanned]).to eq(2)
      expect(report[:corrected]).to eq(1)
    end

    it "non tocca i record già corretti" do
      create(:ticket, organization:, project:, description: "è già corretto")

      report = described_class.call(dry_run: false).value.fetch("Ticketing::Ticket")

      expect(report[:corrected]).to eq(0)
    end

    it "è idempotente" do
      ticket = with_raw(create(:ticket, organization:, project:), description: "e' gia rotto")
      described_class.call(dry_run: false)

      second = described_class.call(dry_run: false)

      expect(second.value.fetch("Ticketing::Ticket")[:corrected]).to eq(0)
      expect(ticket.reload.description).to eq("è già rotto")
    end

    it "rispetta il limite per modello" do
      2.times { with_raw(create(:ticket, organization:, project:), description: "e' rotto") }

      report = described_class.call(dry_run: false, limit: 1).value.fetch("Ticketing::Ticket")

      expect(report[:corrected]).to eq(1)
    end
  end
end
