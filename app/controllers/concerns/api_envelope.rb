# frozen_string_literal: true

# Contratto delle risposte dei canali macchina: envelope `{ data: }` in caso di successo,
# `{ error: { code, message, details? } }` in caso di errore (ErrorRendering), e nessun
# ParamsWrapper. Vale identico per l'API a token di progetto e per la riga di comando.
#
# CYRA-718 — esiste come posto UNICO perché le due basi (Api::BaseController e
# Cli::Api::BaseController) non possono ereditare l'una dall'altra: `Cli::Api` renderebbe ambigua la
# costante `Api`. Prima la seconda RIPETEVA la prima riga per riga, e due copie gemelle divergono
# appena qualcuno tocca una sola delle due — l'errore reso dal framework, per esempio, era coperto
# solo dove qualcuno se n'era ricordato.
module ApiEnvelope
  extend ActiveSupport::Concern
  include ErrorRendering

  included do
    # CYRA-194 — niente ParamsWrapper su nessun canale API. Il default di Rails rinfila il body JSON
    # sotto la chiave singolare del controller (`metric`, `event`, …) e la fonde in
    # `request.request_parameters`: i controller di ingest leggono proprio quello e persistono il
    # payload così com'è, quindi ogni riga si portava dietro una copia integrale di sé stessa (~51%
    # dei campioni metriche, il 100% degli eventi errore). Nessuno legge la chiave wrappata.
    wrap_parameters false
  end

  private

  # Envelope di successo `{ data: ... }`, con `meta:` opzionale (paginazione).
  def render_ok(data, meta: nil)
    payload = { data: data.as_json }
    payload[:meta] = meta if meta
    render json: payload
  end

  # `meta:` come su render_ok (CYRA-777): la creazione può portare con sé un'informazione che non
  # descrive la risorsa creata ma il contesto in cui è nata — un avviso da stampare a chi ha lanciato
  # il comando. Metterlo dentro `data` lo farebbe sembrare un campo della risorsa.
  def render_created(data, meta: nil)
    payload = { data: data.as_json }
    payload[:meta] = meta if meta
    render json: payload, status: :created
  end

  def render_no_content
    head :no_content
  end
end
