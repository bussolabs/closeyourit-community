# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activity::Presenter do
  let(:project) { create(:project) }

  def event(attrs = {})
    create(:activity_event, { subject: project, organization: project.organization }.merge(attrs))
  end

  it "mappa l'icona di created" do
    expect(described_class.new(event(action: "created")).icon).to eq("circle-plus")
  end

  it "la frase 'created' include il nome dell'attore" do
    presenter = described_class.new(event(action: "created", actor_name: "Marco Rossi"))
    expect(presenter.sentence).to include("Marco Rossi")
  end

  it "uses the fallback icon for an unknown action" do
    presenter = described_class.new(build(:activity_event, subject: project, organization: project.organization, action: "weird"))
    expect(presenter.icon).to eq("info")
  end

  it "la frase 'updated' elenca i campi cambiati" do
    presenter = described_class.new(event(action: "updated", data: { "fields" => %w[name key] }))
    expect(presenter.sentence).to include("name").and include("key")
  end

  it "ogni campo modificabile di un progetto ha un nome leggibile in cronologia, non la colonna grezza" do
    fields = Projects::Project.column_names -
             %w[id organization_id created_at updated_at created_by_id last_ticket_number]
    fields += %w[roadmap_enabled] # colonna ritirata: gli eventi vecchi la citano ancora
    missing = fields.product(%i[it en]).reject { |field, locale| I18n.exists?("activity.fields.#{field}", locale) }
    expect(missing).to be_empty
  end

  it "la frase 'updated' senza campi usa il fallback generico" do
    presenter = described_class.new(event(action: "updated", data: {}))
    expect(presenter.sentence).to eq(I18n.t("activity.actions.updated_generic", actor: presenter.actor_name))
  end

  it "actor_name fa fallback su 'unknown' senza attore" do
    presenter = described_class.new(event(actor: nil, actor_name: nil))
    expect(presenter.actor_name).to eq(I18n.t("activity.unknown_actor"))
  end

  it "actor_name snapshot vuoto → usa il nome dell'attore associato (fallback intermedio)" do
    actor = create(:account, name: "Dana Scully")
    presenter = described_class.new(event(actor: actor, actor_name: nil))
    expect(presenter.actor_name).to eq("Dana Scully")
  end
end
