# frozen_string_literal: true

require "rails_helper"

# CYRA-688 — PRODUCT.md dichiara WCAG AA (testo normale >= 4.5:1) e 8 varianti su 10 delle chip
# stavano sotto. Questo guard ricalcola il rapporto di contrasto di OGNI variante della mappa del
# badge, così una tinta nuova sotto soglia diventa un rosso in CI, non un rilievo del prossimo audit.
#
# I token sono i valori oklch della palette Tailwind v4 (copiati da app/assets/builds/tailwind.css,
# tailwindcss-ruby 4.3.1): la palette è una costante upstream — se un aggiornamento di Tailwind la
# cambiasse, aggiornare QUI i valori dal CSS compilato e riverificare.
RSpec.describe "Ui::BadgeComponent — contrasto AA" do
  PALETTE = {
    "gray-100" => [ 0.967, 0.003, 264.542 ], "gray-700" => [ 0.373, 0.034, 259.733 ],
    "red-50" => [ 0.971, 0.013, 17.38 ], "red-700" => [ 0.505, 0.213, 27.518 ],
    "orange-50" => [ 0.980, 0.016, 73.684 ], "orange-700" => [ 0.553, 0.195, 38.402 ],
    "amber-50" => [ 0.987, 0.022, 95.277 ], "amber-700" => [ 0.555, 0.163, 48.998 ],
    "green-50" => [ 0.982, 0.018, 155.826 ], "green-700" => [ 0.527, 0.154, 150.069 ],
    "emerald-50" => [ 0.979, 0.021, 166.113 ], "emerald-700" => [ 0.508, 0.118, 165.612 ],
    "teal-50" => [ 0.984, 0.014, 180.72 ], "teal-700" => [ 0.511, 0.096, 186.391 ],
    "sky-50" => [ 0.977, 0.013, 236.62 ], "sky-700" => [ 0.500, 0.134, 242.749 ],
    "indigo-50" => [ 0.962, 0.018, 272.314 ], "indigo-600" => [ 0.511, 0.262, 276.966 ],
    "violet-50" => [ 0.969, 0.016, 293.756 ], "violet-600" => [ 0.541, 0.281, 293.009 ]
  }.freeze

  def linear_rgb(l, c, h)
    hr = h * Math::PI / 180.0
    a = c * Math.cos(hr)
    b = c * Math.sin(hr)
    l_ = l + (0.3963377774 * a) + (0.2158037573 * b)
    m_ = l - (0.1055613458 * a) - (0.0638541728 * b)
    s_ = l - (0.0894841775 * a) - (1.2914855480 * b)
    l3 = l_**3
    m3 = m_**3
    s3 = s_**3
    [
      (4.0767416621 * l3) - (3.3077115913 * m3) + (0.2309699292 * s3),
      (-1.2684380046 * l3) + (2.6097574011 * m3) - (0.3413193965 * s3),
      (-0.0041960863 * l3) - (0.7034186147 * m3) + (1.7076147010 * s3)
    ].map { |v| v.clamp(0.0, 1.0) }
  end

  def luminance(token)
    r, g, b = linear_rgb(*PALETTE.fetch(token))
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  def contrast(foreground, background)
    hi, lo = [ luminance(foreground), luminance(background) ].minmax.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  it "ogni variante della mappa colori regge il 4,5:1 del testo normale" do
    combos = Ui::BadgeComponent::COLORS.values.map { |style| style[:box].gsub(/dark:\S+ /, "").scan(/bg-([a-z]+-\d+) text-([a-z]+-\d+)/).first }

    offending = combos.filter_map do |background, foreground|
      value = contrast(foreground, background)
      "#{foreground} su #{background}: #{value.round(2)}" if value < 4.5
    end

    expect(offending).to be_empty, "Combinazioni sotto soglia AA:\n#{offending.join("\n")}"
  end

  it "la mappa non contiene tinte fuori dal guard (ogni token usato è nella palette del test)" do
    tokens = Ui::BadgeComponent::COLORS.values.flat_map { |style| style[:box].gsub(/dark:\S+/, "").scan(/(?:bg|text)-([a-z]+-\d+)/).flatten }

    expect(tokens.uniq - PALETTE.keys).to be_empty
  end
end
