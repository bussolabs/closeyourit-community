# frozen_string_literal: true

require "rails_helper"

# Riordino degli elementi di guidance di UN owner secondo ordered_ids (posizione = indice). Idempotente
# e anti cross-owner: agisce solo sulla collection data, gli id estranei sono ignorati (anti-BOLA).
RSpec.describe Guidance::Reorder do
  let(:organization) { create(:organization) }

  it "assegna position pari all'indice nell'ordine richiesto" do
    a = create(:guidance_reference, owner: organization, key: "a", position: 0)
    b = create(:guidance_reference, owner: organization, key: "b", position: 1)
    c = create(:guidance_reference, owner: organization, key: "c", position: 2)

    described_class.call(collection: organization.guidance_references, ordered_ids: [ c.id, a.id, b.id ])

    expect([ c.reload.position, a.reload.position, b.reload.position ]).to eq([ 0, 1, 2 ])
  end

  it "ignora gli id che non appartengono alla collection (anti cross-owner)" do
    mine = create(:guidance_reference, owner: organization, key: "mine", position: 0)
    other = create(:guidance_reference, key: "other", position: 0)

    described_class.call(collection: organization.guidance_references, ordered_ids: [ other.id, mine.id ])

    expect(mine.reload.position).to eq(1)
    expect(other.reload.position).to eq(0)
  end
end
