# frozen_string_literal: true

require "rails_helper"

# Togliere un goal cancella la DEFINIZIONE della conversione, non il traffico: le visite che l'avevano
# soddisfatto restano, semplicemente nessuno le conta più. È la differenza fra smettere di misurare
# una cosa e perdere i dati, e vale la pena averla scritta.
RSpec.describe Analytics::Goals::Delete do
  let(:project) { create(:project) }

  it "elimina il goal e lascia in piedi le visite che lo soddisfacevano" do
    goal = create(:analytics_goal, project:, path_pattern: "/pricing")
    create(:pageview, project:, path: "/pricing")

    result = described_class.call(goal:)

    expect(result).to be_ok
    expect(result.value).to be(true)
    expect(Analytics::Goal.where(id: goal.id)).not_to exist
    expect(Analytics::Pageview.where(project:, path: "/pricing")).to exist
  end

  it "gli altri goal del progetto restano dove sono" do
    goal = create(:analytics_goal, project:, path_pattern: "/a")
    altro = create(:analytics_goal, project:, path_pattern: "/b")

    described_class.call(goal:)

    expect(project.analytics_goals.reload).to eq([ altro ])
  end
end
