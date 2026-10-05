# frozen_string_literal: true

module Monitoring
  # Registry statico dei tool di monitoring (SDK/agent/CLI) che spediamo noi. Catalogo dev-defined →
  # COSTANTE, non tabella CRUD (eccezione enum-static di rules/lookup-tables.md: aggiungere un tool =
  # spedire una nuova libreria = lavoro dev). `code` = il `sdk.name` che il client mette nel body/wire
  # (deve combaciare con Projects::Source#tool_code). label/language/framework sono via i18n
  # (`monitoring.tools.<code>.*`, rules/i18n.md); qui vive solo la struttura (icona/colore/piattaforme).
  class Tool
    # color = chiave Ui::Colors (chip tint dell'icona). platform_codes = hint per il picker "atteso".
    REGISTRY = {
      "closeyourit-ruby"  => { icon: "gem",         color: "rose",   platform_codes: %w[web] },
      "closeyourit-js"    => { icon: "code",        color: "amber",  platform_codes: %w[web] },
      "closeyourit-dart"  => { icon: "smartphone",  color: "sky",    platform_codes: %w[ios android] },
      "closeyourit-agent" => { icon: "server",      color: "violet", platform_codes: [] },
      "closeyourit-cli"   => { icon: "terminal",    color: "teal",   platform_codes: [] }
    }.freeze

    FALLBACK_ICON = "plug"
    FALLBACK_COLOR = "gray"

    def self.codes = REGISTRY.keys
    def self.all = REGISTRY.keys.map { |code| new(code) }
    def self.known?(code) = REGISTRY.key?(code.to_s)
    def self.find(code) = known?(code) ? new(code.to_s) : nil

    attr_reader :code

    def initialize(code)
      @code = code.to_s
    end

    def known? = self.class.known?(code)
    def icon = REGISTRY.dig(code, :icon) || FALLBACK_ICON
    def color = REGISTRY.dig(code, :color) || FALLBACK_COLOR
    def platform_codes = REGISTRY.dig(code, :platform_codes) || []

    # Etichette visibili all'utente via i18n; default = code così un tool ignoto resta leggibile.
    def label = I18n.t("monitoring.tools.#{code}.label", default: code)
    def language = I18n.t("monitoring.tools.#{code}.language", default: "")
    def framework = I18n.t("monitoring.tools.#{code}.framework", default: "")

    def ==(other) = other.is_a?(Tool) && other.code == code
    alias_method :eql?, :==
    def hash = code.hash
  end
end
