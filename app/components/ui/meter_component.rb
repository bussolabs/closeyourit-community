# frozen_string_literal: true

module Ui
  # CYRA-703 — barra orizzontale "etichetta · riempimento · valore" del design system. Una sola forma
  # per tutti i dettagli della scheda di un server: sensori di temperatura, singoli processori,
  # interfacce di rete, memoria di scambio, latenze del disco.
  #
  # Le classi colore sono LETTERALI (lo scanner Tailwind purga le interpolate) e un colore fuori
  # mappa ripiega sul neutro, come StatLabelComponent: una pagina non deve rompersi per una tinta.
  # La larghezza è uno style inline e non una classe perché Tailwind genera solo le classi che trova
  # scritte nel sorgente, e una percentuale calcolata a runtime lì non c'è.
  class MeterComponent < BaseComponent
    COLORS = {
      neutral: "bg-zinc-400",
      indigo: "bg-indigo-500",
      emerald: "bg-emerald-500",
      amber: "bg-amber-500",
      orange: "bg-orange-500",
      red: "bg-red-500",
      sky: "bg-sky-500"
    }.freeze

    DEFAULT_COLOR = :neutral

    def initialize(label:, value_text:, pct:, color: DEFAULT_COLOR, test_id: nil)
      @label = label
      @value_text = value_text
      @pct = pct.to_f.clamp(0, 100)
      @color = color
      @test_id = test_id
    end

    private

    attr_reader :label, :value_text, :test_id

    def fill_class = COLORS.fetch(@color, COLORS.fetch(DEFAULT_COLOR))

    def fill_style = "width: #{format('%.4g', @pct)}%"

    def fill_test_id = test_id.present? ? "#{test_id}-fill" : nil
  end
end
