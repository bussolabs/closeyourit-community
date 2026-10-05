# frozen_string_literal: true

module Ui
  class EntityMarkComponentPreview < ViewComponent::Preview
    # Doppio leggero: il componente, nei rami :glyph e :none, usa solo color/icon/icon_kind.
    # Il ramo :image richiede un ActiveStorage attachment reale → coperto dallo spec, non dalla preview.
    Sample = Struct.new(:color, :icon, :kind) do
      def icon_kind = kind
    end

    def glyph = render(Ui::EntityMarkComponent.new(record: Sample.new("indigo", "rocket", :glyph)))

    def fallback_color = render(Ui::EntityMarkComponent.new(record: Sample.new("emerald", nil, :none)))

    def extra_small = render(Ui::EntityMarkComponent.new(record: Sample.new("violet", "server", :glyph), size: :xs))
  end
end
