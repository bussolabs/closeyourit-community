# frozen_string_literal: true

require "rails_helper"

# Partial del conteggio viewer: è il TARGET (id viewers_<gid>) ri-renderizzato dai broadcast del canale.
# Contratto: id stabile sempre presente; badge (Ui::BadgeComponent + i18n) solo con ≥1 viewer.
RSpec.describe "member/viewers/_count", type: :view do
  let(:ticket) { create(:ticket) }

  it "rende il target stabile con id viewers_<gid> (anche a 0 viewer)" do
    render partial: "member/viewers/count", locals: { resource: ticket, count: 0 }

    expect(rendered).to include(%(id="viewers_#{ticket.to_gid_param}"))
  end

  it "mostra il badge col testo i18n del conteggio quando ≥1" do
    render partial: "member/viewers/count", locals: { resource: ticket, count: 3 }

    expect(rendered).to include(I18n.t("member.presence.viewers_count", count: 3))
    expect(rendered).to include('data-test="viewers-count"')
  end

  it "con 0 viewer il badge è nascosto (solo il target vuoto)" do
    render partial: "member/viewers/count", locals: { resource: ticket, count: 0 }

    expect(rendered).not_to include('data-test="viewers-count"')
  end
end
