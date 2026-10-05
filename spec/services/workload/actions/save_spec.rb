# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workload::Actions::Save, type: :service do
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }
  let(:actor) { create(:account).tap { |a| create(:team_membership, team: team, account: a) } }

  describe "creazione" do
    it "crea la action con gli attributi e imposta created_by" do
      action = Workload::Action.new(team: team)

      result = described_class.call(action: action, attributes: { title: "Fiera Milano" }, actor: actor)

      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.title).to eq("Fiera Milano")
      expect(result.value.created_by).to eq(actor)
    end

    it "titolo vuoto → R422-WORKLOAD-001, nessuna action creata" do
      action = Workload::Action.new(team: team)

      expect do
        result = described_class.call(action: action, attributes: { title: "" }, actor: actor)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-WORKLOAD-001")
      end.not_to change(Workload::Action, :count)
    end

    it "registra un evento 'created' nell'activity-log, scoped all'org del team" do
      action = Workload::Action.new(team: team)

      expect do
        result = described_class.call(action: action, attributes: { title: "Fiera Milano" }, actor: actor)
        expect(result).to be_ok
      end.to change(Activity::Event, :count).by(1)

      event = action.activity_events.last
      expect(event.action).to eq("created")
      expect(event.organization_id).to eq(organization.id)
    end

    it "validazione fallita → nessun evento orfano (rollback atomico)" do
      action = Workload::Action.new(team: team)

      expect do
        described_class.call(action: action, attributes: { title: "" }, actor: actor)
      end.not_to change(Activity::Event, :count)
    end
  end

  describe "activity-log su modifica" do
    it "registra 'updated' coi campi cambiati" do
      action = create(:workload_action, team: team, organization: organization, title: "Originale")

      expect do
        result = described_class.call(action: action, attributes: { title: "Rinominata" }, actor: actor)
        expect(result).to be_ok
      end.to change(Activity::Event, :count).by(1)

      event = action.activity_events.chronological.last
      expect(event.action).to eq("updated")
      expect(event.data["fields"]).to include("title")
    end

    it "NON registra eventi se non cambia nulla" do
      action = create(:workload_action, team: team, organization: organization, title: "Invariata")

      expect do
        described_class.call(action: action, attributes: { title: "Invariata" }, actor: actor)
      end.not_to change(Activity::Event, :count)
    end
  end

  describe "completed_at" do
    it "è impostato quando lo stato diventa done" do
      action = Workload::Action.new(team: team)

      result = described_class.call(action: action, attributes: { title: "X", status: "done" }, actor: actor)

      expect(result.value.completed_at).to be_present
    end

    it "è azzerato quando si esce da done" do
      action = create(:workload_action, :done, team: team, organization: organization)

      result = described_class.call(action: action, attributes: { status: "planned" })

      expect(result.value.completed_at).to be_nil
    end
  end

  describe "partecipanti" do
    it "delega a SetParticipants tenendo solo i membri del team" do
      member = create(:account).tap { |a| create(:team_membership, team: team, account: a) }
      outsider = create(:account)
      action = Workload::Action.new(team: team)

      result = described_class.call(action: action, attributes: { title: "X" },
                                    participant_ids: [ member.id, outsider.id ], actor: actor)

      expect(result).to be_ok
      expect(result.value.participants).to contain_exactly(member)
    end

    it "propaga l'errore dei partecipanti e fa rollback della action" do
      allow(Workload::Actions::SetParticipants).to receive(:call)
        .and_return(Result.err(AppError.new("boom", code: "R422-WORKLOAD-002")))
      action = Workload::Action.new(team: team)

      expect do
        result = described_class.call(action: action, attributes: { title: "X" },
                                      participant_ids: [ SecureRandom.uuid ], actor: actor)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-WORKLOAD-002")
      end.not_to change(Workload::Action, :count)
    end
  end
end
