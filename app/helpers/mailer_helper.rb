# frozen_string_literal: true

# Stile email "engineering-paper". Le email vogliono CSS INLINE (i client strippano classi/<style>),
# quindi qui centralizziamo palette, font e gli stili ricorrenti come stringhe per `style="..."`,
# così i template restano leggibili e DRY. L'accento è semantico per tipo di mail.
module MailerHelper
  # Palette (hex dei token Tailwind nativi del design system).
  MAIL_CANVAS    = "#f5f5f4" # stone-100 (sfondo)
  MAIL_CARD      = "#ffffff" # superficie
  MAIL_SUBTLE    = "#fafaf9" # footer / meta box
  MAIL_BORDER    = "#e7e5e4" # stone-200
  MAIL_INK       = "#18181b" # zinc-900 (header, titoli)
  MAIL_TEXT      = "#3f3f46" # zinc-700 (corpo)
  MAIL_SECONDARY = "#6b7280" # gray-500
  MAIL_MUTED     = "#9ca3af" # gray-400
  MAIL_ACCENT    = "#4f46e5" # indigo-600

  # Accento semantico per tipo evento (riga sotto l'header + dettagli).
  ACCENTS = { indigo: "#4f46e5", red: "#dc2626", amber: "#d97706", green: "#16a34a" }.freeze
  # Tinte soft per pill/badge (corrispondenti agli accenti).
  ACCENTS_SOFT = { indigo: "#eef2ff", red: "#fef2f2", amber: "#fffbeb", green: "#f0fdf4" }.freeze

  FONT_SANS    = "'Inter',-apple-system,'Segoe UI',Roboto,system-ui,sans-serif"
  FONT_DISPLAY = "'Space Grotesk','Segoe UI',system-ui,sans-serif"
  FONT_MONO    = "'JetBrains Mono',ui-monospace,'SF Mono',Menlo,Consolas,monospace"

  # indigo (default: reset/invito) · red (nuovo errore / uptime down) · amber (regressione / lentezza) · green (recovery)
  def mail_accent_key_for(event_type = nil)
    case event_type.to_s
    when "error_new", "error_spike", "uptime_down"    then :red
    when "error_regression", "uptime_slow"            then :amber
    when "uptime_up"                                   then :green
    else :indigo
    end
  end

  def mail_accent_for(event_type = nil) = ACCENTS[mail_accent_key_for(event_type)]
  def mail_accent_soft_for(event_type = nil) = ACCENTS_SOFT[mail_accent_key_for(event_type)]

  # I client di posta non risolvono i path relativi: gli url snapshottati sulle notifiche sono `/member/...`,
  # quindi il link va assolutizzato con l'host di `default_url_options` (per-environment: example.com in test,
  # localhost in dev, MAIL_HOST in prod) — MAI un host hardcoded. La guardia `start_with?("http")` rende il
  # metodo idempotente sugli url già assoluti (reset password, invito), così non si raddoppia l'host.
  def mail_absolute_url(url)
    value = url.to_s
    return value if value.blank? # url opzionale: senza link non si inventa un host nudo (le view testuali non hanno guardia)

    value.start_with?("http") ? value : "#{root_url.chomp('/')}#{value}"
  end

  # Stili inline riusabili (stringhe per attributo style).
  def mail_overline_style
    "margin:0 0 4px 0;font-family:#{FONT_MONO};font-size:10px;font-weight:500;" \
      "letter-spacing:1.2px;text-transform:uppercase;color:#{MAIL_MUTED};"
  end

  def mail_h1_style(size: 21)
    "margin:0 0 14px 0;font-family:#{FONT_DISPLAY};font-size:#{size}px;font-weight:600;" \
      "line-height:1.35;color:#{MAIL_INK};"
  end

  def mail_p_style
    "margin:0 0 14px 0;font-family:#{FONT_SANS};font-size:14px;line-height:1.6;color:#{MAIL_TEXT};"
  end

  def mail_note_style
    "margin:24px 0 0 0;font-family:#{FONT_SANS};font-size:12.5px;line-height:1.6;color:#{MAIL_SECONDARY};"
  end

  def mail_footnote_style
    "margin:14px 0 0 0;font-family:#{FONT_SANS};font-size:11.5px;line-height:1.6;color:#{MAIL_MUTED};"
  end

  def mail_mono_style(color: MAIL_TEXT)
    "font-family:#{FONT_MONO};font-size:12px;color:#{color};"
  end
end
