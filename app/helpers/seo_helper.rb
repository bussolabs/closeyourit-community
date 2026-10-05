# frozen_string_literal: true

# Colori della sezione SEO (CYRA-528). Il colore è semantico, non decorativo: rosso solo per ciò che
# toglie davvero la pagina dai risultati, così un elenco pieno di rosso significa qualcosa.
module SeoHelper
  SEVERITY_COLORS = {
    "critical" => :red,
    "high" => :orange,
    "medium" => :amber,
    "low" => :sky
  }.freeze

  AREA_COLORS = {
    "indexability" => :indigo,
    "structure" => :violet,
    "content" => :teal,
    "i18n" => :sky,
    "performance" => :amber
  }.freeze

  # Gli URL delle pagine arrivano dalla scansione del sito del cliente e finiscono in un `href`
  # cliccabile. `Seo::Site#base_url` è validato come http(s), `Seo::Page#url` no: qui si controlla
  # allo schema prima di renderlo un link, così un `javascript:` non diventa mai cliccabile per chi
  # apre l'elenco. Nil quando lo schema non è ammesso — chi chiama rende il testo senza link.
  def seo_safe_url(url)
    scheme = URI.parse(url.to_s).scheme&.downcase
    url if %w[http https].include?(scheme)
  rescue URI::InvalidURIError
    nil
  end

  def seo_severity_color(severity) = SEVERITY_COLORS.fetch(severity.to_s, :gray)

  def seo_area_color(area) = AREA_COLORS.fetch(area.to_s, :gray)

  def seo_area_label(area) = t("seo.areas.#{area}", default: area.to_s)

  # Il codice di stato come lo legge una persona: verde se la pagina risponde, rosso se non c'è.
  def seo_status_color(status_code)
    case status_code.to_i
    when 200..299 then :emerald
    when 300..399 then :amber
    when 400..599 then :red
    else :gray
    end
  end

  # La prova, resa leggibile: un jsonb crudo in pagina è un dato, non una spiegazione.
  def seo_evidence_rows(issue)
    issue.evidence.except("url").map do |key, value|
      [ t("seo.evidence.#{key}", default: key.humanize), seo_evidence_value(value) ]
    end
  end

  def seo_evidence_value(value)
    case value
    when Array then value.map { |item| seo_evidence_value(item) }.join(", ")
    when Hash then value.map { |key, nested| "#{key}: #{seo_evidence_value(nested)}" }.join(" · ")
    else value.to_s
    end
  end

  # --- Core Web Vitals (CYRA-537) ---

  # Il colore di un esito. Tre fasce, non quattro: i CWV hanno tre soglie e la resa di Google è
  # verde/ambra/rosso. Riusare la scala a quattro delle gravità (che ha :orange in mezzo) farebbe
  # leggere «da migliorare» come «gravità alta», che è un'altra cosa.
  VITALS_COLORS = {
    good: :emerald,
    needs_improvement: :amber,
    poor: :red
  }.freeze

  def seo_vital_color(rating) = VITALS_COLORS.fetch(rating&.to_sym, :gray)

  # Classi LETTERALI: lo scanner di Tailwind non vede le interpolate, e un colore costruito a runtime
  # semplicemente non finisce nel CSS — la barra resterebbe trasparente senza errori.
  VITALS_TEXT = {
    good: "text-emerald-600 dark:text-emerald-400", needs_improvement: "text-amber-600 dark:text-amber-400", poor: "text-red-600 dark:text-red-400"
  }.freeze
  VITALS_BAR = {
    good: "bg-emerald-500", needs_improvement: "bg-amber-500", poor: "bg-red-500"
  }.freeze

  def seo_vitals_text_color(rating) = VITALS_TEXT.fetch(rating&.to_sym, "text-gray-400 dark:text-zinc-500")
  def seo_vitals_bar_color(rating) = VITALS_BAR.fetch(rating&.to_sym, "bg-stone-300 dark:bg-zinc-600")

  # La chiave con cui Google identifica una metrica nelle distribuzioni. Sta qui e non nella vista:
  # è un dettaglio del contratto di quell'API, e la vista non deve conoscerlo.
  def seo_field_key(metric)
    return Seo::PageSpeed::Constants::CLS_FIELD_KEY if metric.to_s == "cls"

    Seo::PageSpeed::Constants::FIELD_METRICS.key(:"field_#{metric}_ms")
  end

  # L'esito, calcolato SEMPRE qui e mai preso da chi manda il dato: il client che misura calcola
  # anche lui un giudizio, e fidarsene vorrebbe dire lasciare che sia il misurato a darsi il voto.
  def seo_vital_rating(metric, value) = Seo::Vitals.rating(metric, value)

  # Il nome della fascia come si legge a schermo. Sta accanto al colore, non al suo posto: un
  # verdetto affidato al solo colore non arriva a chi non lo distingue (WCAG AA).
  def seo_vital_rating_label(rating)
    return t("seo.vitals.ratings.unknown") if rating.blank?

    t("seo.vitals.ratings.#{rating}")
  end

  # La misura come si legge: secondi con un decimale sopra il secondo, millisecondi sotto, e tre
  # decimali per il CLS, che è adimensionale e si muove su valori piccoli. Un valore assente resta
  # un trattino, mai uno zero.
  def seo_vital_value(metric, value)
    return "—" if value.nil?
    return number_with_precision(value, precision: 3) if Seo::Vitals.unitless?(metric)
    return t("seo.vitals.units.seconds", value: number_with_precision(value / 1000.0, precision: 1)) if value >= 1000

    t("seo.vitals.units.milliseconds", value: value.round)
  end

  # Quando è stato controllato l'ultima volta, e se quel giro è andato male (CYRA-536). Tre esiti
  # distinti, mai uno che somigli a un altro: mai controllato, controllato e fallito, controllato e
  # basta. Un giro fallito che si legge come un sito a posto è la cosa peggiore che questa pagina
  # possa fare.
  def seo_site_last_check_text(site)
    return t("member.monitoring.seo_sites.never_audited") if site.last_audited_at.blank?
    return t("member.monitoring.seo_sites.failed", error: site.last_error) if site.last_error.present?

    t("member.monitoring.seo_sites.checked_ago", duration: time_ago_in_words(site.last_audited_at))
  end
end
