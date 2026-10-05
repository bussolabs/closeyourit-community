# frozen_string_literal: true

module Ui
  # Marchio visivo di un progetto/gruppo accanto al nome. Precedenza (vedi Iconable#icon_kind):
  #   1. immagine caricata → tile con <img object-cover>;
  #   2. icona Lucide → chip col tint del colore (Ui::Colors.chip) + Ui::IconComponent;
  #   3. nessuna delle due → tile pieno col colore (Ui::Colors.swatch), fallback.
  # `record` risponde a `color`, `icon`, `icon_image`, `icon_kind` (concern Iconable).
  class EntityMarkComponent < BaseComponent
    SIZES = {
      xs: { box: "w-5 h-5", icon: "text-[10px]" },
      sm: { box: "w-6 h-6", icon: "text-[11px]" }
    }.freeze
    DEFAULT_SIZE = :sm

    def initialize(record:, size: DEFAULT_SIZE, **options)
      @record = record
      @size = size.to_sym
      @size = DEFAULT_SIZE unless SIZES.key?(@size)
      @options = options
    end

    private

    attr_reader :record

    def kind = record.icon_kind
    def box = SIZES.fetch(@size)[:box]
    def icon_size = SIZES.fetch(@size)[:icon]
    def chip_classes = Ui::Colors.chip(record.color)
    def swatch_classes = Ui::Colors.swatch(record.color)
    def image_path = helpers.rails_blob_path(record.icon_image, disposition: :inline)
  end
end
