# frozen_string_literal: true

require "rails_helper"

# Revocare è la sola via d'uscita da una pubblicazione: l'indirizzo è già in giro, quindi deve sparire
# davvero. Il progetto e le sue statistiche non si toccano — si chiude la porta, non si butta la stanza.
RSpec.describe Analytics::Links::Revoke do
  let(:project) { create(:project) }

  it "elimina il link e lascia intatto il progetto" do
    link = create(:analytics_link, project:)

    result = described_class.call(link:)

    expect(result).to be_ok
    expect(result.value).to be(true)
    expect(Analytics::Link.where(id: link.id)).not_to exist
    expect(Projects::Project.where(id: project.id)).to exist
  end

  it "revokes all active links of the same project" do
    link = create(:analytics_link, project:)
    create(:analytics_link, project:)

    described_class.call(link:)

    expect(project.analytics_links.reload).to be_empty
  end

  it "revoca anche un link protetto da password: il lucchetto non lo trattiene" do
    link = create(:analytics_link, :with_password, project:)

    expect(described_class.call(link:)).to be_ok
    expect(Analytics::Link.where(id: link.id)).not_to exist
  end
end
